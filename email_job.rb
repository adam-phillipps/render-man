require 'gmail'
require 'active_support'
require 'active_support/core_ext'
require 'byebug'

class EmailJob
  def initialize
    count = 0
    ac = 0
    begin
      # gmail.inbox.find(:unread).each do |email|
      gmail.inbox.find(:all).each do |email|
        puts count += 1
        info_hash = Hash[(email.body.to_s[/\n\n\n(.*)\t\t\n\n--==Multipart_Boundary/m,1]).scan(/([^:]+):\s(.*)[$\n]+/)]
        puts info_hash
        email.star!
        email.message.attachments.each do |f|
          puts "attachments count: #{ac += 1}"
          version = Time.now.to_i
          name, dot, type  = f.filename.gsub(' ', '_').rpartition('.')
          team_id = info_hash['Team ID']
          new_name = [team_id, version.to_s].join('_') + dot + type
          File.write(File.join(file_dir, new_name), f.body.decoded)
       
          sleep 3 # pretending to render
          
          # set the file to go to start AE's rendering job
          signal_a_e_to_start
          # loop for the done file to begin compiling the email to send to the "finished" inbox
          # pick up the file in finished and name it the long name
          send_email_after_render_completes(new_name, email.body)
          # find useful error/exception handling, if needed
          email.read!
        end
      end
    rescue => e
      puts e
    end
  end

  def send_email(file_name, message_body)
    gmail.deliver do
      to 'pointway@gmail.com'
      subject file_name
      text_part do
        body message_body
      end
      html_part do
        content_type 'text/html; charset=UTF-8'
        body message_body
      end
      # add_file File.join('F:', 'finished', file_name)
      add_file File.join(file_dir, file_name)
    end
  end

  def signal_a_e_to_start
    # File.delete(File.join('F:', 'Done')) if done_file_exists?
    # f = File.new(File.join('F:', 'Go'), 'a+')
    File.delete(File.join(file_dir, 'Done')) if done_file_exists?
    f = File.new(File.join(file_dir, 'Go'), 'a+')
    f.close
  end

  def gmail
    username ||= 'personalization@endwave.com'
    password ||= 'focus123'
    @gmail ||= Gmail.connect(username, password)    
  end

  def file_dir
    Dir.pwd
  end

  def done_file_exists?
    puts 'checking for done file'
    # File.file?(File.join('/', 'Users', 'adam', 'code', 'F', 'Done'))
    File.file?(File.join(file_dir, 'Done'))
  end

  def send_email_after_render_completes(file_name, message_body)
    loop do
      return send_email(file_name, message_body) if done_file_exists?
      sleep 3 # wait longer for the done file, if it doesn't exist yet
    end
  end
end

EmailJob.new