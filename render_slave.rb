require 'dotenv'
Dotenv.load
require 'aws-sdk'
require 'httpparty'

class RenderSlave
  def initialize
    @id = HTTParty.get('http://169.254.169.254/latest/meta-data/instance-id')
    @refresh_time = boot_time
    creds = Aws::Credentials.new(
      ENV['AWS_ACCESS_KEY_ID'], ENV['AWS_SECRET_ACCESS_KEY'])
    @s3 = Aws::S3::Client.new(region: ENV['AWS_REGION'],
      credentials: creds)
    @s3_resource = Aws::S3::Resource.new(region: ENV['AWS_REGION'],
      credentials: creds)
    @ec2 = Aws::S3::Client.new(region: ENV['AWS_REGION'],
      credentials: creds)
    @backlog = Aws::S3::Bucket.new(
      region: 'us-west-2', credentials: creds, name: 'render-test')
    @wip = Aws::S3::Bucket.new(
      region: 'us-west-2', credentials: creds, name: 'render-wip-test')
    @finished = Aws::S3::Bucket.new(
      region: 'us-west-2', credentials: creds, name: 'render-finished-test')
    poll
  end

  def boot_time
    @ec2.describe_instances(instance_ids:[@id]).reservations[0].instances[0].launch_time
  end

  def poll
    until should_stop? do
      sleep rand(571) / 137.0 # offsets polling for other slaves
      job = @backlog.objects.first.object # get the oldest file
      unless job_in_wip?(job)
        job = move_to(job, @backlog, @wip)
        run job
      end
    end
    @ec2.terminate_instancers(ids: [@id])
  end

  def should_stop?
    if time_left < 300
      if death_ratio_acheived?
        true
      else
        @refresh_time += 3900 # adds another hour and compensates for the 5 minutes
        false
      end
    else
      false
    end
  end

  def job_in_wip?(job)
    begin
      @wip.object(job.key).content_length > 0
    rescue Aws::S3::Errors::NotFound
      puts 'nil job, not moving to wip'
      false
    end
  end

  def time_left
    3300.0 - (Time.now.to_i - @refresh_time)
  end

  def death_ratio_acheived?
    wip = @wip.objects.count
    wip = wip == 0 ? 0.01 : wip # guards agains dividing by zero
    (@backlog.objects.count / wip) <= 10.0
  end

  def run(job)
    # run the render job
    sleep 5
    move_to(job, @wip, @finished)
  end

  def move_to(job,source,target)
    key = job.key
    @s3.copy_object(
      bucket: target.name,
      copy_source: "#{source.name}/#{key}",
      key: "#{key}")
    @s3.delete_object(
      bucket: source.name,
      key: key)
    @wip.object key
  end
end

RenderSlave.new