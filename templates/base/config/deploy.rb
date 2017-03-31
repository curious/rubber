# This is a sample Capistrano config file for rubber

# Curious: configure newrelic deployment notification hooks
require 'new_relic/recipes'
# Curious: ensure that bundler installs gems during deployment into shared/bundle
require 'bundler/capistrano'
# Curious: This is for deploy:web:enable and deploy:web:disable tasks
require 'capistrano/maintenance'

set :rails_env, Rubber.env

# Curious: configure capistrano multistage (capistrano-ext gem) to allow custom
# deployment rules per environment,
set :stages, %w(production qa externaldev partners)
set :default_stage, Rubber.env
require 'capistrano/ext/multistage'

on :load do
  set :application, rubber_env.app_name
  set :runner,      rubber_env.app_user
  set :deploy_to,   "/mnt/#{application}-#{Rubber.env}"
  set :copy_exclude, [".git/*", ".bundle/*", "log/*", ".rvmrc", ".rbenv-version", ".ruby-version", ".git", ".bundle"] # Curious: don't deploy empty .git/.bundle directories
  # Curious: removed in favor of our own asset handling
  # set :assets_role, [:app, :resque] # Curious: precompile assets on resque machines that may need to send background emails
end

# Curious: Deploy from our private github repository.  Deploy works using ssh keys forwarded
# from the server running Capistrano.  When a developer runs 'cap deploy', the server
# will attempt to access Github using the developer's ssh key.  When Jenkins runs
# 'cap deploy', the server will attempt to access Github using the ssh key for the
# jenkins@<build server> key, which must be manually added to the 'curious-builds'
# account on Github.
# See http://help.github.com/deploy-with-capistrano/
set :scm, "git"
set :repository, "git@github.com:curious/curious_com.git"
set :deploy_via, :remote_cache
set :ssh_options, { :forward_agent => true }
set :git_enable_submodules, 1 # tell git to fetch our vendor/* submodules
# :branch is set in multistage files

# Easier to do system level config as root - probably should do it through
# sudo in the future.  We use ssh keys for access, so no passwd needed
set :user, 'root'
set :password, nil

# Use sudo with user rails for cap deploy:[stop|start|restart]
# This way exposed services (mongrel) aren't running as a privileged user
set :use_sudo, true

# If you're having troubles connecting to your server, uncommenting this
# line will give you more verbose logging output from net-ssh, which will
# make debugging the problem much easier.
#set :ssh_log_level, :debug

# How many old releases should be kept around when running "cleanup" task
set :keep_releases, 3

# Lets us work with staging instances without having to checkin config files
# (instance*.yml + rubber*.yml) for a deploy.  This gives us the
# convenience of not having to checkin files for staging, as well as
# the safety of forcing it to be checked in for production.
set :push_instance_config, Rubber.env != 'production'

# don't waste time bundling gems that don't need to be there
set :bundle_without, [:development, :test, :staging] if Rubber.env == 'production'

# Curious: don't try to touch assets after the deploy - they're on s3
set :normalize_asset_timestamps, false

# Allow us to do N hosts at a time for all tasks - useful when trying
# to figure out which host in a large set is down:
# RUBBER_ENV=production MAX_HOSTS=1 cap invoke COMMAND=hostname
max_hosts = ENV['MAX_HOSTS'].to_i
default_run_options[:max_hosts] = max_hosts if max_hosts > 0

# Allows the tasks defined to fail gracefully if there are no hosts for them.
# Comment out or use "required_task" for default cap behavior of a hard failure
rubber.allow_optional_tasks(self)

# Wrap tasks in the deploy namespace that have roles so that we can use FILTER
# with something like a deploy:cold which tries to run deploy:migrate but can't
# because we filtered out the :db role
namespace :deploy do
  rubber.allow_optional_tasks(self)
  tasks.values.each do |t|
    if t.options[:roles]
      task t.name, t.options, &t.body
    end
  end
end

namespace :deploy do
  namespace :assets do
    rubber.allow_optional_tasks(self)
    tasks.values.each do |t|
      if t.options[:roles]
        task t.name, t.options, &t.body
      end
    end
  end
end

# Curious: Customize the maintenance page created by capistrano's deploy:web:disable task.
# See https://github.com/tvdeyen/capistrano-maintenance
# See https://github.com/capistrano/capistrano/commit/4ece7902d5 for discussion
# of the removal of deploy:web:enable and deploy:web:diable from capistrano-core.
# use local template instead of included one with capistrano-maintenance
set :maintenance_template_path, 'app/views/layouts/maintenance.html.erb'
# disable the warning on how to configure your server
set :maintenance_config_warning, false

require "net/http"

namespace :deploy do
  namespace :assets do
    # Curious: Since we're precompiling locally, we need to ship the manifest file off to the servers.
    task :deploy_manifest, :roles => [:web, :resque_worker], :except => {:no_release => true} do
      source = "public/assets/manifest.json"
      destination = "#{release_path}/public/assets/manifest.json"
      puts "Uploading from #{source} to #{destination}"
      # otherwise the upload will complain about the dir not being there.
      run "mkdir -p #{release_path}/public/assets"
      top.upload(source, destination)
    end
  end

  # Curious: Create a symlink to a secret.yml file containing various credentials
  desc "Symlink secret file"
  task :symlink_secret_file do
    run "ln -sf /home/app/.secret.yml #{release_path}/config/secret.yml"
  end

  # Curious: Convenience tasks for deploying secret credentials to newly-created servers.
  namespace :credentials do
    desc "Copy secrets file to a remote server"
    task :secret_file do
      target_path = "/home/app/.secret.yml"
      secret_file_path_local = Capistrano::CLI.ui.ask("Full path to secret.yml file for *#{rails_env}* environment: ")
      content = File.read(File.expand_path(secret_file_path_local))
      if content.include?("s3_secret_access_key") && content.include?("aws_secret_access_key") && content.include?("db_password")
        put(content, target_path, :mode => 0400)
        rsudo "chown #{rubber_env.app_user}:#{rubber_env.app_user} #{target_path}"
      else
        fail "File must include at least s3_secret_access_key, aws_secret_access_key and db_password"
      end
    end
  end
end

# load in the deploy scripts installed by vulcanize for each rubber module
Dir["#{File.dirname(__FILE__)}/rubber/deploy-*.rb"].sort.each do |deploy_file|
  load deploy_file
end

# capistrano's deploy:cleanup doesn't play well with FILTER
after "deploy", "cleanup"
after "deploy:migrations", "cleanup"
task :cleanup, :except => { :no_release => true } do
  count = fetch(:keep_releases, 5).to_i

  rsudo <<-CMD
    all=$(ls -x1 #{releases_path} | sort -n);
    keep=$(ls -x1 #{releases_path} | sort -n | tail -n #{count});
    remove=$(comm -23 <(echo -e "$all") <(echo -e "$keep"));
    for r in $remove; do rm -rf #{releases_path}/$r; done;
  CMD
end

# Curious: removed in favor of our own asset handling
# # We need to ensure that rubber:config runs before asset precompilation in Rails, as Rails tries to boot the environment,
# # which means needing to have DB access.  However, if rubber:config hasn't run yet, then the DB config will not have
# # been generated yet.  Rails will fail to boot, asset precompilation will fail to complete, and the deploy will abort.
# if Rubber::Util.has_asset_pipeline?
#   load 'deploy/assets'
#
#   callbacks[:after].delete_if {|c| c.source == "deploy:assets:precompile"}
#   callbacks[:before].delete_if {|c| c.source == "deploy:assets:symlink"}
#   before "deploy:assets:precompile", "deploy:assets:symlink"
#   after "rubber:config", "deploy:assets:precompile"
# end

# Curious: After the code gets updated, create a symlink to the secret file
after "deploy:update_code", "deploy:symlink_secret_file"

# Curious: Notify NewRelic of deployments so they will show up on our performance graphs.
# See https://rpm.newrelic.com/accounts/79699/applications/1158697/deployments
after "deploy:migrations", "newrelic:notice_deployment"

# Curious: Allow execution of rake tasks on remote machines
# See http://stackoverflow.com/questions/312214/how-do-i-run-a-rake-task-from-capistrano
desc "Run a task on a remote server."
# run like: RUBBER_ENV=qa FILTER=qa01 cap invoke_rake task=a_certain_task
task :invoke_rake do
  run("cd #{deploy_to}/current; #{rake} #{ENV['task']} RAILS_ENV=#{rails_env}")
end

# Curious: added our own asset handling
namespace :deploy do
  # We'll only run the asset sync stuff when the job says to do that explicitly.
  # We don't want to separate them into separate tasks, because then we can't order it as finely.
  task :migrations_with_assets do
    if Rubber::Util.has_asset_pipeline?
      before "deploy:update_code" do
        # HM: run the precompile locally
        puts run_locally "bundle exec rake assets:precompile RAILS_ENV=#{rails_env} RAILS_GROUPS=assets"
        # Now ship everything to S3
        puts run_locally "bundle exec rake assets:sync RAILS_ENV=#{rails_env} RAILS_GROUPS=assets"
      end
      # HM: take the asset manifest that was precompiled locally and ship it to the servers
      # We do this after the code is updated, as otherwise the new release directory won't be ready.
      after "deploy:update_code", "deploy:assets:deploy_manifest"
    end
    migrations
  end

  # This won't precompile or sync assets, but it WILL upload the manifest file that was compiled previously.
  task :migrations_with_manifest do
    if Rubber::Util.has_asset_pipeline?
      # HM: take the asset manifest that was precompiled locally (previously) and ship it to the servers
      # We do this after the code is updated, as otherwise the new release directory won't be ready.
      after "deploy:update_code", "deploy:assets:deploy_manifest"
    end
    migrations
  end

  # There are 3 choices for the DOWNTIME environment variable:
  # - no_downtime (or nil): Do not go into maintenance mode
  # - down_and_up: Go into maintenance mode after updating code and assets. Come out of maintenance after the deploy finishes (if successful)
  # - down_only: Go into maintenance mode after updating code and assets. Do not come out of maintenance (must be done manually)
  # NOTE: it's important that this is at the end of the file, because ideally we want this to be the last thing
  # that happens before & after.
  downtime = ENV['DOWNTIME']
  if downtime == "down_and_up" || downtime == "down_only"
    after "deploy:update_code", "deploy:web:disable"
  end
  if downtime == "down_and_up"
    after "deploy:migrations", "deploy:web:enable"
  end
end

# Curious: added tasks for managing cron daemon
namespace :rubber do
  # General tasks for managing cron daemon on all servers.
  namespace :cron do
    desc "Starts cron daemon"
    task :start do
      rsudo "service cron start"
    end

    desc "Stops cron daemon"
    task :stop do
      rsudo "service cron stop || true"
    end

    desc "Restart cron daemon"
    task :restart do
      stop
      start
    end
  end
end

# Curious: added maintenance tasks that not only do the standard capistrano-maintenance
# things, but also pause cron and resque so they don't try to run while we're
# in maintenance mode.
namespace :deploy do
  namespace :maintenance do
    desc "Present a maintenance page to visitors, pauses background jobs and tasks."
    task :disable do
      find_and_execute_task("deploy:web:disable")
      find_and_execute_task("rubber:resque:worker:pause")
      # QQQ: is there a way to run this task only for role => tools, without
      #      having to restrict the general 'rubber:cron:stop' job to tools-only?
      find_and_execute_task("rubber:cron:stop")
    end

    desc "Makes the application web-accessible again, resumes background jobs and tasks."
    task :enable do
      find_and_execute_task("deploy:web:enable")
      find_and_execute_task("rubber:resque:worker:resume")
      find_and_execute_task("rubber:cron:start")
    end
  end
end