require 'dotenv'
Dotenv.load
require 'aws-sdk'
require 'httparty'
require 'byebug'

class RenderSlave
  def initialize
    byebug
    poll
  end

  def poll
    until should_stop? do
      sleep rand(571) / 137.0
      # could add message_attribute_names to gather namespaced messages
      # from the queue
      backlog_poller.poll(
        default_wait_time: nil,
        max_number_of_messages: 1,
        visibility_timeout: 900
      ) do |msg|
        begin
          update_status(wip_address, msg)
          run_job(msg)
          update_status(finished_address, msg)
        rescue
        # if there's an error during job processing,
        # the message becomes available again
          throw :skip_delete
        end
      end
    end
    ec2.terminate_instancers(ids: [self_id])
  end

  def should_stop?
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
  
  # should the message and/or file be renamed now?
  def update_status(board, message)
    sqs.send_message({
      queue_url: board,
      message_body: message.body,
      message_attributes: message.attributes
    })
  end

  def run_job(msg)
    byebug  
    file = s3.get_object(
      response_target: '/path/to/file',
      bucket: 'backlogtester', # customer in
      key: 'object-key'
    )
    start_rendiering(file)
    File.open('C:\\', 'rb') do |file|
      s3.put_object(bucket: 'wiptest2', key: '', body: file)
    end
  end

  def backlog_poller
    @backlog_poller ||= Aws::SQS::QueuePoller.new(backlog_address)
  end

  def sqs
    @s3 ||= Aws::S3::Client.new(
      region: ENV['AWS_REGION'],
      credentials: creds
    )
  end

  def start_rendering(file)
    sleep 10
  end

  def backlog_address
    'https://sqs.us-west-2.amazonaws.com/088617881078/backlog_smashanalytics_sqs'
  end

  def sqs
    @sqs ||= Aws::SQS::Client.new(credentials: creds)
  end

  def wip_address
    'https://sqs.us-west-2.amazonaws.com/088617881078/wip_smashanalytics_sqs'
  end

  def finished_address
    'https://sqs.us-west-2.amazonaws.com/088617881078/finished_smashanalytics_sqs'
  end

  def boot_time
    @boot_time ||= Time.now.to_i#ec2.describe_instances(instance_ids:[@id]).reservations[0].instances[0].launch_time
  end

  def self_id
    'adsflkj'
    # @id ||= HTTParty.get('http://169.254.169.254/latest/meta-data/instance-id')
  end

  def ec2
    @ec2 ||= Aws::EC2::Client.new(region: ENV['AWS_REGION'],
      credentials: creds)
  end

  def creds
    @creds ||= Aws::Credentials.new(
      ENV['AWS_ACCESS_KEY_ID'], ENV['AWS_SECRET_ACCESS_KEY'])
  end
end

RenderSlave.new