require 'dotenv'
Dotenv.load
require 'aws-sdk'
Aws.use_bundled_cert!
require 'httparty'
require 'byebug'
require 'logger'
require 'zip/zip'

class RenderSlave
  def initialize
    poll
  end

  def poll
    until should_stop? do
      puts 'Polling....'
      sleep rand((571 / 137.0) * 100) / 100
      backlog_poller.poll(
        wait_time_seconds: nil,
        max_number_of_messages: 1,
        visibility_timeout: 30 # keep message invisible long enough to process to wip
      ) do |msg, stats|
        puts 'Polling....'
        begin
          if JSON.parse(msg.body).has_key?('Records')
            puts "\n\nRunable job found:\n#{JSON.parse(msg.body)}"
            job = Job.new(msg, backlog_address)
            run_job(job)
            puts "finished job:\n #{job.key}\n\n"
          else
            sqs.delete_message({
              queue_url: backlog_address,
              receipt_handle: msg.receipt_handle
            })
          end
        rescue => e
          puts "\n line 38\n#{e}\n\n"
        # if there's an error during job processing,
        # the message becomes available again
          throw :skip_delete
          break
        end
      end
    end
    ec2.terminate_instancers(ids: [self_id])
  end

  def should_stop?
    # if you're the last one, (in active state) don't kill yourself
    if hour_mark_approaches?
      death_ratio_acheived? ? true : false
    else
      false
    end
  end

  def hour_mark_approaches?
    ((Time.now.to_i - boot_time) % 3600) > 3300
  end

  def death_ratio_acheived?
    death_ratio >= 10
  end

  def death_ratio
    counts = [finished_address, wip_address].map do |board|
      sqs.get_queue_attributes(
        queue_url: board,
        attribute_names: ['ApproximateNumberOfMessages']
      ).attributes['ApproximateNumberOfMessages'].to_f
    end

    wip = counts[1]
    wip = wip == 0.0 ? 1.0 : wip # guards against dividing by zero
    counts[0] / wip
  end

  def run_job(job)
    if job.board == backlog_address
      job.pull_file_from_backlog
      job.update_status
      job.unzip_file
      job.signal_a_e_to_start
      job.wait_for_a_e_to_finish
      job.push_file_to_finished
      job.update_status
      job.clean_up_for_next_job
    else
      puts "*********************************'\n\
        job doesn't exist;  from #run_job:\n#{job.key}"
    end
  end

  def s3
    @s3_client ||= Aws::S3::Client.new(
      region: ENV['AWS_REGION'],
      credentials: creds
    )
  end

  def backlog_poller
    @backlog_queue_poller ||= Aws::SQS::QueuePoller.new(backlog_address)
  end

  def backlog_address
    'https://sqs.us-west-2.amazonaws.com/088617881078/backlog_smashanalytics_sqs'
  end

  def sqs
    @sqs_client ||= Aws::SQS::Client.new(credentials: creds)
  end
  
  def wip_address
    'https://sqs.us-west-2.amazonaws.com/088617881078/wip_smashanalytics_sqs'
  end

  def finished_address
    'https://sqs.us-west-2.amazonaws.com/088617881078/finished_smashanalytics_sqs'
  end

  def boot_time
    @instance_boot_time ||= ec2.describe_instances(instance_ids:[@id]).reservations[0].instances[0].launch_time
  end

  def self_id
    @id ||= HTTParty.get('http://169.254.169.254/latest/meta-data/instance-id')
  end

  def ec2
    @ec2_client ||= Aws::EC2::Client.new(region: ENV['AWS_REGION'],
      credentials: creds)
  end

  def creds
    @credentials ||= Aws::Credentials.new(
      ENV['AWS_ACCESS_KEY_ID'], ENV['AWS_SECRET_ACCESS_KEY'])
  end

  def setup_logger
    logger_client = Logger.new(
      File.open(File.expand_path('../render_slave.log', __FILE__), 'a+')
    )
    logger_client.level = Logger::INFO
    logger_client
  end

  def logger
  #   logger.info("\njob started: #{stats.last_message_received_at}\n#{JSON.parse(msg.body)}\n#{msg}\n\n")
  #  @logger_client ||= setup_logger
  end

  class Job < RenderSlave
    attr_reader :msg, :board
    def initialize(msg, board)
      @msg = msg
      @board = board
    end

    def key
      body['Records'].first['s3']['object']['key']
    end

    def receipt_handle
      @receipt_handle ||= msg.receipt_handle
    end

    def body
      JSON.parse(msg.body)
    end

    def update_status
      puts "updating message status.  check in #{next_board}"
      resp = sqs.send_message({
        queue_url: next_board,
        message_body: body
      })

      sqs.delete_message({
        queue_url: previous_board,
        receipt_handle: receipt_handle
      })
      @receipt_handle = resp.receipt_handle
    end

    def previous_board
      board == finished_address ? wip_address : backlog_address
    end

    def next_board
      board == backlog_board ? wip_address : finished_address
    end

      def pull_file_from_backlog
        begin
          s3.get_object(
            response_target: file_path,
            bucket: 'backlog-pointway', # customer in
            key: key
          )
        rescue Aws::S3::Errors::NoSuchKey => e
          puts "No matching file in backlog:\n#{e}"
        end
    end

    def unzip_file
      if file_path =~ /\.zip/
        Zip::ZipFile.open(file_path) do |zip_file|
         zip_file.each do |f|
           f_path = File.join('F:', 'backlog', f.name)
           FileUtils.mkdir_p(File.dirname(f_path))
           zip_file.extract(f, f_path) unless File.exist?(f_path)
         end
        end
      end
    end

    def done_file_exists?
      File.file?(File.join('F:', 'Done'))
    end

    def file_path # fix name/path for windows
      location = done_file_exists? ? 'finished' : 'backlog'
      File.join('F:', location, key)
    end

    def signal_a_e_to_start
      File.delete(File.join('F:', 'Done')) if done_file_exists?
      f = File.new(File.join('F:', 'Go'), 'a+') # fix name/path for windows
      f.close
    end

    def wait_for_a_e_to_finish
      loop do
        return push_file_to_finished if File.file?(File.join('F:', 'Done')) # fix name/path for windows
        sleep 3
      end
    end

    def push_file_to_finished
      File.open(file_path, 'rb') do |file|
        puts "Pushing file:\n#{key}\n"
        puts s3.put_object(bucket: 'finished-pointway', key: key, body: file)
        file.close
      end
    end

    def clean_up_for_next_job
      delete_from_local_context
      File.delete(File.join('F:', 'Done')) # fix for windows path
      delete_from_backlog_queue
      delete_from_backlog_bucket
      delete_from_local_context
    end

    def delete_from_backlog_queue
      sqs.delete_message(
        queue_url: backlog_address,
        receipt_handle: receipt_handle
      )
    end

    def delete_from_local_context
      File.delete(file_path)
    end

    def delete_from_backlog_bucket
      begin
        s3.delete_object(
          bucket: 'backlog-pointway',
          key: key
          )
      rescue => e
      end
    end
  end # end Job
end

RenderSlave.new