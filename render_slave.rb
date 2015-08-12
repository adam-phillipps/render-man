require 'dotenv'
Dotenv.load
require 'aws-sdk'
require 'httpparty'
require 'byebug'

class RenderSlave
  def initialize
    @id = HTTParty.get('http://169.254.169.254/latest/meta-data/instance-id')
    @refresh_time = boot_time
    creds = Aws::Credentials.new(
      ENV['AWS_ACCESS_KEY_ID'], ENV['AWS_SECRET_ACCESS_KEY'])
    @s3 = Aws::S3::Client.new(region: ENV['AWS_REGION'],
      credentials: creds)
    @ec2 = Aws::S3::Client.new(region: ENV['AWS_REGION'],
      credentials: creds)
    @backlog = Aws::S3::Bucket.new(
      region: 'us-west-2', credentials: creds, name: 'render-test')
    @wip = Aws::S3::Bucket.new(
      region: 'us-west-2', credentials: creds, name: 'render-wip-test')
    @finished = Aws::S3::Bucket.new(
      region: 'us-west-2', credentials: creds, name: 'render-finished-test')
    url = URI.parse('http://www.example.com/index.html')
    req = Net::HTTP::Get.new(url.to_s)
    res = Net::HTTP.start(url.host, url.port) {|http|
      http.request(req)
    }
    puts res.body
    byebug
    poll
  end

  def boot_time
    @ec2.describe_instances(instance_ids:[@id]).reservations[0].instances[0].launch_time
  end

  def poll
    until should_stop? do
      byebug
      sleep rand(571) / 137.0 # offsets polling for other slaves
      job = @backlog.objects.first.object
      unless job_in_wip?(job)
        byebug
        job = move_to(job, @backlog, @wip)
        run job
      end
    end
    @ec2.terminate_instancers(ids: [@id])
  end

  def should_stop?
    byebug
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

  def job_in_wip?(job)
    byebug
    begin
      @wip.object(job.key).content_length > 0
    rescue Aws::S3::Errors::NotFound
      puts 'nil job, not moving to wip'
    end
  end

  def time_left
    byebug
    3300.0 - (Time.now.to_i - @refresh_time)
  end

  def low_ratio_of_backlog_to_wip?
    byebug
    wip = @wip.objects.count
    wip = wip == 0 ? 0.01 : wip # guards agains dividing by zero
    (@backlog.objects.count / wip) <= 10.0
  end

  def run(job)
    byebug
    # run the render job
    sleep 5
    move_to(job, @wip, @finished)
  end

  def move_to(job,source,target)
    byebug
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