require_relative './render'

class Job
  include Render
  attr_reader :msg, :board

  def initialize(msg, board)
    @msg = msg
    @board = board
  end

  def body
    JSON.parse(plain_text_body)
  end

  def completion_handler
    lambda do |notification|
      if (notification['jobId'] == job_id && ['COMPLETED', 'ERROR'].include?(notification['state']))
        notification_worker.stop
      end
    end
  end

  def create_elastic_transcoder_job(input_key, preset_id, output_key_prefix)
    transcoder_client = Aws::ElasticTranscoder::Client.new(region: region, credentials: creds)
    input = { key: input_key }
    output = {
      # key: Digest::SHA256.hexdigest(input_key.encode('UTF-8')),
      key: finished_key,
      preset_id: preset_id
    }

    transcoder_client.create_job(
      pipeline_id: pipeline_id,
      input: input,
      output_key_prefix: output_key_prefix,
      outputs: [ output ]
    )[:job][:id]
  end

  def delete_from_local_context
    puts 'deleting from local'
    FileUtils.rm_rf Dir.glob("#{dir_path}/*")
  end

  def delete_from_backlog_bucket
    puts 'deleting from backlog bucket'
      s3.delete_object(
        bucket: 'backlog-pointway',
        key: key
        )
  end

  def done_file_exists?
    File.file?(File.join(a_e_dir, 'Done'))
  end

  def dir_path
    location = done_file_exists? ? 'finished' : 'backlog'
    File.join(a_e_dir, location)
  end

  def output_key_prefix
    key.split('_').first + '/'
  end

  def file_path # fix name/path for windows
    location = done_file_exists? ? 'finished' : 'backlog'
    File.join(a_e_dir, location, key)
  end

  def key
    body['Records'].first['s3']['object']['key']
  end

  def finished_key
    key.gsub('.zip', '.mov')
  end

  def next_board
    board == backlog_address ? wip_address : finished_address
  end

  def plain_text_body
    msg.body
  end

  def previous_board
    board == finished_address ? wip_address : backlog_address
  end

  def pull_file_from_backlog
    puts 'pulling from backlog'
    resp = s3.get_object(
      response_target: file_path,
      bucket: 'backlog-pointway', # customer in
      key: key
    )
    puts 'finished pulling'
  end

  def receipt_handle
    @receipt_handle ||= msg.receipt_handle
  end

  def update_status
    resp = sqs.send_message(
      queue_url: next_board,
      message_body: plain_text_body
    )

    @board = next_board
    sqs.delete_message(
      queue_url: previous_board,
      receipt_handle: receipt_handle
    )

    @wip_message_id = resp.message_id
  end

  def unzip_file_and_unpack
    if file_path =~ /\.zip/
      unzip_file
      destination = '/Users/adam/code/F/backlog/'

      Dir.glob(File.join(file_path, '*')).each do |file|
        if File.exists? File.join(destination, File.basename(file))
          FileUtils.move file, File.join(destination, "1-#{File.basename(file)}")
        else
          FileUtils.move file, File.join(destination, File.basename(file))
        end
      end
    end
  end

  def unzip_file
    puts 'unzipping file'  
    Zip::ZipFile.open(file_path) do |zip_file|
     zip_file.each do |f|
       f_path = File.join(a_e_dir, 'backlog', f.name)
       FileUtils.mkdir_p(File.dirname(f_path))
       zip_file.extract(f, f_path) unless File.exist?(f_path)
     end
    end
  end

  def finished_file_path
    file_path.gsub('.zip', '.mov')
  end

  def push_file
    loop do
      return push_file_to_video_in if done_file_exists?
      sleep 3 # wait longer for the done file, if it doesn't exist yet
    end
  end

  def push_file_to_video_in
    puts 'pushing to finished bucket'
    resp = ''
    File.open(finished_file_path, 'rb') do |file|
      puts "Pushing file:\n#{finished_file_path}\n"
      resp = s3.put_object(bucket: video_in, key: finished_key, body: file)
      file.close
    end
    resp
  end

  def signal_a_e_to_start
    puts 'signaling ae to start'
    File.delete(File.join(a_e_dir, 'Done')) if done_file_exists?
    File.rename(Dir.glob("#{a_e_dir}/**/*.mp4").first, finished_file_path.gsub('backlog', 'finished')) ##################testing
    f = File.new(File.join(a_e_dir, 'Go'), 'w')
    f.close
  end

  def transcode_from_video_in
    puts 'transcode job started...'
    transcode_job_id = ''
    File.open(finished_file_path, 'rb') do |file|
      transcode_job_id = create_elastic_transcoder_job(finished_key, preset_id, output_key_prefix)
    end
    puts transcode_job_id
  end

  def clean_up_for_next_job
    delete_from_local_context
    if File.file?(File.join(a_e_dir, 'Done'))
      File.delete(File.join(a_e_dir, 'Done')) # fix for windows path
    end
    delete_from_backlog_queue
    delete_from_backlog_bucket
    delete_from_local_context
  end    

  def delete_from_backlog_queue
    puts 'deleting from backlog queue'
    sqs.delete_message(
      queue_url: backlog_address,
      receipt_handle: receipt_handle
    )
  end

  def notification_worker
    @notification_worker ||= SqsQueueNotificationWorker.new(region, sqs_queue_url)
  end

  def start_notification_worker
    notification_worker.add_handler(completion_handler)
    notification_worker.start
  end
end