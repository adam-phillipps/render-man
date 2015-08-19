require 'dotenv'
Dotenv.load
require 'aws-sdk'
require 'byebug'

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
        { name: 'tag:Name', values: ['RenderSlave-initial'] }]).
          images.first.image_id
      @spot_fleet_request_ids = []
#      kill_everything
      poll
    end

    def poll
      poller = Aws::SQS::QueuePoller.new(
        'https://sqs.us-west-2.amazonaws.com/828660616807/backlog')
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
      wip = wip == 0 ? 0.01 : wip # guards agains dividing by zero
      (@backlog.objects.count.to_f / wip)
    end

    def start_slaves(instance_count)
      
      fleet = @ec2.request_spot_fleet(
        spot_fleet_request_config: slave_fleet_params(instance_count))
      # get instanct numbers or request numbers and store them
      @spot_fleet_request_ids << fleet.spot_fleet_request_ids
    end

    def appropriate_ratio_for_starting(count)
      ratio = (count / 10.0).floor
      ratio == 0 ? 1 : ratio
    end

    def slave_fleet_params(instance_count)
      params = {
        client_token: 'Render Slave ok',
        spot_price: '0.12',
        target_capacity: instance_count,
        iam_fleet_role: 'arn:aws:iam::828660616807:role/render-man_fleet_request',
        launch_specifications: slave_fleet_launch_specifications }
    end

    def slave_fleet_launch_specifications
      launch_specifications = []
      available_instance_types.each do |inst_type|
        launch_specifications << {
          image_id: @ami_id,
          key_name: 'RenderSlave',
          instance_type: 't2.micro',#inst_type,
          monitoring: { enabled: true }}
      end
      launch_specifications
    end

    def available_instance_types
      ['m4.large', 'm3.large']
    end

    def kill_everything
      begin
        @ec2.cancel_spot_fleet_requests(
          spot_fleet_request_ids: all_ids,
          terminate_instances: true
        )
        active_instance_ids = all_ids.map do |id|
          @ec2.describe_spot_fleet_instances(
            spot_fleet_request_id: id).
            active_instances.map{ |x| x.instance_id }.flatten
          end
        @ec2.terminate_instances(instance_ids: active_instance_ids)
      rescue => e
        puts e
      end
    end

    def all_ids
      (@spot_fleet_request_ids + fleet_request_ids_from_aws).flatten
    end

    def fleet_request_ids_from_aws
      @ec2.describe_spot_fleet_requests.spot_fleet_request_configs.
        map!{ |request| request.spot_fleet_request_id }
    end

  rescue => e
    puts e
    kill_everything
  end
end

SpotMaker.new