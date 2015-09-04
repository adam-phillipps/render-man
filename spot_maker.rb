require 'dotenv'
Dotenv.load
require 'aws-sdk'
require 'date'

class SpotMaker
  begin
    def initialize
      creds = Aws::Credentials.new(
        ENV['AWS_ACCESS_KEY_ID'], ENV['AWS_SECRET_ACCESS_KEY'])
      @backlog = Aws::S3::Bucket.new(
        region: 'us-west-2', credentials: creds, name: 'render-test')
      @wip = Aws::S3::Bucket.new(
        region: 'us-west-2', credentials: creds, name: 'render-wip-test')    
      @s3 = Aws::S3::Client.new(
        region: ENV['AWS_REGION'], credentials: creds)
      @ec2 = Aws::EC2::Client.new(
        region: ENV['AWS_REGION'], credentials: creds)
      @ami_id = @ec2.describe_images(filters: [
        { name: 'tag:Name', values: ['RenderSlave-prod'] }]).
          images.first.image_id
      @ami_id ||= 'ami-875041b7'
      @spot_fleet_request_ids = []
      poll
    end

    def poll
      poller = Aws::SQS::QueuePoller.new(
        'https://sqs.us-west-2.amazonaws.com/828660616807/backlog_test')
      poller.poll do |msg|
        poller.delete_message(msg) 
        run_program
      end
    end

    def run_program
      ratio = birth_ratio
      start_slaves(appropriate_ratio_for_starting(ratio)) if ratio >= 1#0
      poll
    end

    def birth_ratio
      wip = @wip.objects.count.to_f
      wip = wip == 0 ? 1.0 : wip # guards agains dividing by zero
      (@backlog.objects.count.to_f / wip)
    end

    def start_slaves(instance_count)      
      fleet = @ec2.request_spot_fleet(
        spot_fleet_request_config: slave_fleet_params(instance_count))
      # get instanct numbers or request numbers and store them
    end

    def appropriate_ratio_for_starting(ratio)
      adjusted_ratio = (ratio / 10.0).floor
      adjusted_ratio == 0 ? 1 : adjusted_ratio
    end

    def slave_fleet_params(instance_count)
      params = {
        client_token: "RenderSlave-#{SecureRandom.hex}",
        spot_price: '0.12',
        target_capacity: instance_count,
        terminate_instances_with_expiration: true,
        iam_fleet_role: 'arn:aws:iam::828660616807:role/render-man_fleet_request',
        launch_specifications: slave_fleet_launch_specifications }
    end

    def slave_fleet_launch_specifications
      launch_specifications = []
      available_instance_types.each do |inst_type|
        launch_specifications << {
          image_id: @ami_id,
          key_name: 'RenderSlave',
          instance_type: inst_type,
          monitoring: { enabled: true }}
      end
      launch_specifications
    end

    def available_instance_types
      ['m3.medium', 'm3.large']
    end

  rescue => e
    puts e
    kill_everything
  end
end

SpotMaker.new