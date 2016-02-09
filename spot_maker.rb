require 'dotenv'
Dotenv.load
require 'aws-sdk'
require 'date'
require 'byebug'

class SpotMaker
  begin
    def initialize
      poll
    end

    def creds
      @creds ||= Aws::Credentials.new(ENV['AWS_ACCESS_KEY_ID'], ENV['AWS_SECRET_ACCESS_KEY'])
    end

    def ec2_master
      @ec2_master ||= Aws::EC2::Client.new(region: 'us-west-2', credentials: creds)
    end

    def ec2_clients
      @ec2_clients ||= {}
      {}.tap do
        regions.each do |region|
          @ec2_clients[region] ||= Aws::EC2::Client.new(region: region, credentials: creds)
        end
      end
      @ec2_clients
    end

    def ec2_clients_and_avail_zones_map
      @client_zone_map ||= {}
      ec2_clients.map do |region, client|
        @client_zone_map[region] ||= {
          client: client,
          availability_zones: availability_zones_for_client(client)
        }
      end
    end

    def regions
      @regions ||= ec2_master.describe_regions.regions.map(&:region_name)
    end

    def availability_zones_for_client(client)
      client.describe_availability_zones.availability_zones.map(&:zone_name)
    end

    def all_availability_zones
      @zones ||= ec2_clients.map do |region, client|
                            client.describe_availability_zones.
                              availability_zones.map(&:zone_name)
                          end.flatten
    end

    def slave_image_id
      slave_image.image_id || 'ami-53f0e363' 
    end

    def slave_image
      @slave_image ||= ec2_master.describe_images(
        filters: [{ name: 'tag:Name', values: ['RenderSlave'] }]
      ).images.first
    end

    def slave_image_tags
      slave_image.tags
    end

    def backlog_address
      @bmb ||= 'https://sqs.us-west-2.amazonaws.com/088617881078/backlog_smashanalytics_sqs'
    end

    def wip_address
      @wmb ||= 'https://sqs.us-west-2.amazonaws.com/088617881078/wip_smashanalytics_sqs'
    end

    def sqs_client
      @sqs_client ||= Aws::SQS::Client.new(credentials: creds)
    end

    def available_instance_types
      #['m3.medium', 'm3.large']
      ['t1.micro', 'm1.small']
    end

    def poll
      loop do
        sleep 5
        run_program(adjusted_birth_ratio) if birth_ratio_acheived? || @tbr
      end
    end

    def run_program(desired_instance_count)
      # region_price_map = map_request_and_cheapest_region
      region_price_map = best_price(slave_image)
      ec2_clients[region_price_map[0]].request_spot_fleet(
        spot_fleet_request_config: slave_fleet_params(desired_instance_count, region_price_map[1])
      )
      poll
    end

    def adjusted_birth_ratio
      adjusted_ratio = (birth_ratio / 10.0).floor
      adjusted_ratio == 0 ? 1 : adjusted_ratio
    end
    
    def birth_ratio_acheived?
      !!(birth_ratio >= 10)
    end

    def birth_ratio
      @tbr = true
      counts = ['backlog', 'wip'].map { |board| check_number(board) }
      wip = counts[1]
      wip = wip == 0.0 ? 1.0 : wip # guards against dividing by zero
      counts[0] / wip
    end

    def check(board, attrs = [])
      address = board == 'backlog' ? backlog_address : wip_address
      sqs_client.get_queue_attributes(queue_url: address, attribute_names: attrs)
    end

    def check_number(board)
      check(board, ['ApproximateNumberOfMessages']).attributes.values.first.to_f
    end

    def slave_fleet_params(instance_count)
      # this would call a method to compare different regions for appropriate params vs spot_price
      params = {
        client_token: "RenderSlave-#{SecureRandom.hex}",
        spot_price: best_price, # '0.12',
        target_capacity: instance_count,
        terminate_instances_with_expiration: true,
        iam_fleet_role: 'arn:aws:iam::828660616807:role/render-man_fleet_request',
        launch_specifications: slave_fleet_launch_specifications
      }
    end

     def best_price(image)
      # byebug
      spot_prices = []
      all_availability_zones.each do |az|
        # byebug
        spot_prices = ec2_clients.map do |region, client|
          # byebug
          params_array = spot_price_history_params(availability_zones_for_client(client))
          # byebug
          params_array.map do |params|
            # byebug
            puts params
            client.describe_spot_price_history(params)
          end
        end
      end
      byebug
      best_match = spot_prices.each.map(&:spot_price_history).flatten.
        map{ |sph| {spot_price: sph.spot_price, availability_zone: sph.availability_zone, instance_type: sph.instance_type} }.
          min_by {|sp| sp[:price]}
      byebug
      best_match[:spot_price] = (best_match[:spot_price].to_f + 
        (best_match[:spot_price].to_f*0.2)).round(3).to_s # TODO: add a method that does this 20% increase, etc.
      byebug
      best_match
    end

    def spot_price_history_params(availability_zones)
      # byebug
      availability_zones.map do |zone|
        { 
          start_time: (Time.now + 36000).iso8601.to_s,
          instance_types: slave_image_tags.select { |t| t.key.eql? 'instance_types' }.first.value.split(','),
          product_descriptions: slave_image_tags.select{ |t| t.key.eql? 'product_descriptions' }.first.value.split(','),
          availability_zone: zone
        }
      end
    end

    def slave_fleet_launch_specifications
      launch_specifications = []
      available_instance_types.each do |inst_type|
        launch_specifications << {
          image_id: @ami_id,
          key_name: 'RenderSlave',
          instance_type: inst_type,
          monitoring: { enabled: true }
        }
      end
      launch_specifications
    end

  rescue => e
    puts e
    kill_everything
  end
end

SpotMaker.new