require 'dotenv'
Dotenv.load
require 'aws-sdk'
require 'httparty'
require 'byebug'

class KillAll
  def initialize
    creds = Aws::Credentials.new(
      ENV['AWS_ACCESS_KEY_ID'], ENV['AWS_SECRET_ACCESS_KEY'])
    @ec2 = Aws::EC2::Client.new(region: ENV['AWS_REGION'],
      credentials: creds)
    byebug
    kill_everything
  end
  def kill_everything
      begin
        byebug
        @ec2.cancel_spot_fleet_requests(
          spot_fleet_request_ids: fleet_request_ids_from_aws,
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

    def fleet_request_ids_from_aws
      @ec2.describe_spot_fleet_requests.spot_fleet_request_configs.
        map!{ |request| request.spot_fleet_request_id }
    end
end

KillAll.new
