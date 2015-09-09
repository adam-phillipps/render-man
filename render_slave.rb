require 'dotenv'
Dotenv.load
require 'aws-sdk'
require 'httparty'
require 'logger'

class RenderSlave
  def initialize
    begin
      @file = File.open('render_slave.log', 'a')#File::APPEND)
      @logger = Logger.new(@file)
      @logger.level = Logger::INFO
      @id = HTTParty.get('http://169.254.169.254/latest/meta-data/instance-id')
      @boot_time = boot_time
      creds = Aws::Credentials.new(
        ENV['AWS_ACCESS_KEY_ID'], ENV['AWS_SECRET_ACCESS_KEY'])
      @s3 = Aws::S3::Client.new(region: ENV['AWS_REGION'],
        credentials: creds)
      @s3_resource = Aws::S3::Resource.new(region: ENV['AWS_REGION'],
        credentials: creds)
      @ec2 = Aws::EC2::Client.new(region: ENV['AWS_REGION'],
        credentials: creds)
      @backlog = Aws::S3::Bucket.new(
        region: 'us-west-2', credentials: creds, name: 'render-backlog-test')
      @wip = Aws::S3::Bucket.new(
        region: 'us-west-2', credentials: creds, name: 'render-wip-test')
      @finished = Aws::S3::Bucket.new(
        region: 'us-west-2', credentials: creds, name: 'render-finished-test')
      @log = Aws::S3::Bucket.new(
        region: 'us-west-2', credentials: creds, name: 'render-log')
      @logger.info("RenderSlave ID: #{@id} ----> boot time: #{@boot_time}")
      poll
      @logger.info("Shutting down...")
      @file.close
      @logger.close
      s3_log(@file)
      @ec2.terminate_instancers(ids: [@id])
    rescue e
      @logger.fatal("FATAL ERROR: #{e}")
      s3_log(@file)
    end
  end

  def boot_time
    @boot_time ||= @ec2.describe_instances(instance_ids:[@id]).reservations[0].instances[0].launch_time
  end

  def s3_log(file)
    @log.put_object({
      acl: 'bucket-owner-full-control',
      key: "#{DateTime.now} - #{@id}",
      body: file,
      })
  end

  def poll
    begin
      until should_stop? do
        sleep rand(571) / 137.0 # offsets polling for other slaves
        job = @backlog.objects.first.object # get the oldest file
        unless job_in_wip?(job)
          job = move_to(job, @backlog, @wip)
          run job
        end
      end
    rescue => e
      @logger.fatal("fatal error in poll: #{e}")
    end
  end

  def should_stop?
    if hour_mark_approaches?
      @logger.info("Hour mark approaching: #{@boot_time} -> #{DateTime.now}")
      if death_ratio_acheived?
        @logger.info("Death ratio (#{ratio}) acheived")
        true
      else
        false
      end
    else
      false
    end
  end

  def job_in_wip?(job)
    begin
      @wip.object(job.key).exists?
    rescue Aws::S3::Errors::NotFound
      false
    end
  end

  def hour_mark_approaches?
    ((Time.now.to_i - @boot_time) % 3600) > 3300
  end

  def ratio
    wip = @wip.objects.count
    wip = wip == 0 ? 0.01 : wip # guards agains dividing by zero
    (@backlog.objects.count / wip)
  end

  def death_ratio_acheived?
    ratio <= 10.0
  end

  def run(job)
    unless job.nil?
      @logger.info("running job: #{job.key}")
      # run the render job
      sleep 5
      move_to(job, @wip, @finished)
    end
  end

  def move_to(job,source,target)
    key = job.key
    @s3.copy_object(
      bucket: target.name,
      copy_source: "#{source.name}/#{key}",
      key: key)
    @s3.delete_object(
      bucket: source.name,
      key: key)
    target.object key
  end
end

RenderSlave.new