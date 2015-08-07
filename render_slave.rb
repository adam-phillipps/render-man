require 'aws-sdk'
require 'byebug'

class RenderSlave
  def initialize
    @refresh_time = boot_time
    creds = Aws::Credentials.new(
      ENV['AWS_ACCESS_KEY_ID'], ENV['AWS_SECRET_ACCESS_KEY'])
    @s3 = Aws::S3::Client.new(region: ENV['AWS_REGION'],
      credentials: creds)
    @ec2 = Aws::S3::Client.new(region: ENV['AWS_REGION'],
      credentials: creds)
    @backlog = 'render-test'
    @wip = 'render-wip'
    byebug
    poll
  end

  def boot_time
    # get ec2 boot time
    Time.now.to_i
  end

  def poll
    until should_stop? do
      job = @s3.list_objects(@backlog).objects.first
      move_to_wip_with job.key
      run job
    end
  end

  def low_ratio_of_backlog_to_wip?
    byebug
    wip = @s3.list_objects(bucket: 'render-wip').contents.count
    wip = wip == 0 ? 0.01 : wip # guards agains dividing by zero
    (@s3.list_objects(bucket: 'render-test').contents.count / wip) <= 10.0
  end

  def should_stop?
    if time_left < 300
      if low_ratio_of_backlog_to_wip?
        true
      else
        @refresh_time += 3900 # adds another hour and compensates for the 5 minutes
        false
      end
    else
      false
    end
  end

  def run(job)
    # run the render job
    sleep 5
  end

  def time_left
    3300 - (Time.now.to_i - @refresh_time)
  end

  def move_to_wip_with(key)
    byebug
    backlog = @s3_client.buckets[@backlog]
    wip = @s3_client.buckets[@wip]
    source_object = backlog.objects[key]
    target_object = wip.objects[key]
    source_object.copy_to(target_object)
    @s3_client.delete_object(
      bucket: backlog,
      key: key)
  end
end

RenderSlave.new