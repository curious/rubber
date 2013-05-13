# Curious: we have customized the resque initializer to support using the
# MockRedis gem in test mode, and to set a custom namespace for redis keys.

require 'yaml'
require 'resque'

# See https://github.com/defunkt/resque
# Tell resque gem which redis servers to talk to in various environments.
rails_root = ENV['RAILS_ROOT'] || File.dirname(__FILE__) + '/../..'
rails_env = ENV['RAILS_ENV'] || 'development'

if rails_env == 'test'
  Resque.redis = MockRedis.new
else
  redis_host = 'localhost:6379'

  resque_yml = rails_root + '/config/resque.yml'
  if File.exist? resque_yml
    resque_config = YAML.load_file(resque_yml)
    redis_host = resque_config[rails_env]

    # we've got to do a little leg work to calculate the port when running under parallel_test
    if ENV['TEST_ENV_NUMBER']
      tmp = redis_host.match /(.*:)(\d+)/
      redis_host = tmp[1] + (tmp[2].to_i + ENV['TEST_ENV_NUMBER'].to_i).to_s if tmp.length == 3
    end
  end

  Resque.redis = redis_host

  # Set namespace to avoid collision between jobs posted by different apps to the same redis server
  Resque.redis.namespace = "resque:PlayerPrototype:#{rails_env}#{ENV['TEST_ENV_NUMBER']}"
end