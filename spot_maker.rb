require 'dotenv'
Dotenv.load
require 'aws-sdk'
require 'date'
require 'byebug'
require 'securerandom'

class SpotMaker
  begin
    def initialize
      # this decides how many instances need to run and/or start.  this is the denominator
      # of the ratio    ->     backlog / wip
      JOBS_RATIO_DENOMINATOR = 10
      IAM_FLEET_ROLE = 'arn:aws:iam::828660616807:role/render-man_fleet_request'
      poll
    end

     def poll
      loop do
        sleep 5
        run_program(adjusted_birth_ratio) if birth_ratio_acheived? || true
      end
    end

    def birth_ratio_acheived?
      birth_ratio >= JOBS_RATIO_DENOMINATOR
    end

    def birth_ratio
      counts = [backlog_address, wip_address].map do |board|
        sqs.get_queue_attributes(
          queue_url: board,
          attribute_names: ['ApproximateNumberOfMessages']
        ).attributes['ApproximateNumberOfMessages'].to_f
      end

      backlog = counts.first
      wip = counts.last
      wip = wip == 0.0 ? 1.0 : wip # guards against irrational values
      backlog / wip
    end

    def adjusted_birth_ratio
      adjusted_ratio = (birth_ratio / JOBS_RATIO_DENOMINATOR).floor
      adjusted_ratio == 0 ? 1 : adjusted_ratio
    end

    def run_program(desired_instance_count)
      ec2.request_spot_fleet(
        dry_run: true,
        spot_fleet_request_config: slave_fleet_params(desired_instance_count)
      )
      poll
    end

    def slave_fleet_params(instance_count)
      bp = best_price # only want the method to run once
      price = bp[:spot_price] 
      availability_zone = bp[:availability_zone]
      {
        client_token: "RenderSlave-#{SecureRandom.hex}",
        spot_price: price, # '0.12',
        target_capacity: instance_count,
        terminate_instances_with_expiration: true,
        iam_fleet_role: IAM_FLEET_ROLE,
        launch_specifications: slave_fleet_launch_specifications(availability_zone)
      }
    end

    def best_price(image = slave_image)
      best_match = spot_prices.each.map(&:spot_price_history).
        flatten.map do |sph|
          { 
            spot_price: sph.spot_price,
            availability_zone: sph.availability_zone,
            instance_type: sph.instance_type 
          }
        end.min_by { |sp| sp[:price] }

      # make sure this markup in max spot price is wanted
      best_match[:spot_price] = (best_match[:spot_price].to_f +
                                                (best_match[:spot_price].to_f*0.15)).round(3).to_s
      best_match
    end

    def spot_prices
      @spot_prices = []
      if @spot_prices.empty?
        availability_zones.each do |az|
          @spot_prices << ec2.describe_spot_price_history(
            spot_price_history_params(az)
          )
        end
      end
      @spot_prices # this is a hash with the availability zone, instance type and recommended bid
    end

    # not caching for the same reason as slave_fleet_params (allows config via aws console via ami tags)
    def slave_fleet_launch_specifications(availability_zone)
      slave_image_tag_filter('instance_types').map do |inst_type|
        {
          image_id: slave_image.image_id,
          key_name: 'RenderSlave',
          instance_type: inst_type,
          monitoring: { enabled: true },
          placement: { availability_zone: availability_zone }
        }
      end
    end

    def slave_image_tag_filter(tag_name)
      slave_image.tags.find { |t| t.key.include?(tag_name) }.value.split(',')
    end

    def slave_image
      @slave_image ||= ec2.describe_images(
        filters: [{ name: 'tag:Name', values: ['RenderSlave'] }]
      ).images.first
    end

    def availability_zones
      @az ||= ec2.describe_availability_zones.
                      availability_zones.map(&:zone_name)
    end

    def spot_price_history_params(availability_zone)
        { 
          start_time: (Time.now + 36000).iso8601.to_s,
          instance_types: slave_image_tag_filter('instance_types'),#s.select { |t| t.key.eql?  }.first.value.split(','),
          product_descriptions: slave_image_tag_filter('product_descriptions'),#slave_image.tags.select{ |t| t.key.eql? 'product_descriptions' }.first.value.split(','),
          availability_zone: availability_zone
        }
    end

    def creds
      @creds ||= Aws::Credentials.new(ENV['AWS_ACCESS_KEY_ID'], ENV['AWS_SECRET_ACCESS_KEY'])
    end

    def ec2
      @ec2 ||= Aws::EC2::Client.new(region: 'us-west-2', credentials: creds)
    end

    def sqs
      @sqs ||= Aws::SQS::Client.new(credentials: creds)
    end

    def backlog_address
      'https://sqs.us-west-2.amazonaws.com/088617881078/backlog_smashanalytics_sqs'
    end

    def wip_address
      'https://sqs.us-west-2.amazonaws.com/088617881078/wip_smashanalytics_sqs'
    end

  rescue => e
    puts e
    kill_everything
  end
end

SpotMaker.new