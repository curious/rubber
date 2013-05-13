namespace :rubber do

  namespace :passenger_nginx do
  
    rubber.allow_optional_tasks(self)
  
    after "rubber:install_gems", "rubber:passenger_nginx:custom_install"
    
    task :custom_install, :roles => :passenger_nginx do
      rubber.sudo_script 'install_passenger_nginx', <<-ENDSCRIPT
        # Check if there is an nginx with the required version and passenger built in.
        if [ -x /usr/sbin/nginx ]
          then echo 'Found nginx on system'
          pax=$(/usr/sbin/nginx -V 2>&1 | awk '/nginx\\/#{rubber_env.nginx_version}/{a++}/passenger-#{rubber_env.passenger_version}/{b++} END {print a&&b}')
          if [ $pax -eq 1 ]
            then echo 'Nginx/Passenger version matches'
            exit 0
          fi
        fi
        # Lets install
        echo 'Installing / Upgrading nginx #{rubber_env.nginx_version}'
        TMPDIR=`mktemp -d` || exit 1
        cd $TMPDIR
        echo 'Downloading'
        wget -qN http://nginx.org/download/nginx-#{rubber_env.nginx_version}.tar.gz
        echo 'Unpacking'
        tar xf nginx-#{rubber_env.nginx_version}.tar.gz
        # Curious: we include the http_realip_module so that we can target the client's actual ip
        # rather than seeing the load-balancer's ip.  We use this to whitelist ips in
        # pre-prod domains.
        passenger-install-nginx-module --auto --prefix=/opt/nginx --nginx-source-dir=$TMPDIR/nginx-#{rubber_env.nginx_version} --extra-configure-flags="--conf-path=/etc/nginx/nginx.conf --error-log-path=/var/log/nginx/error.log --http-log-path=/var/log/nginx/access.log --lock-path=/var/lock/nginx.lock --pid-path=/var/run/nginx.pid --sbin-path=/usr/sbin/nginx --with-http_gzip_static_module --with-http_realip_module"
      ENDSCRIPT
    end

    after "rubber:setup_app_permissions", "rubber:passenger_nginx:setup_passenger_permissions"

    task :setup_passenger_permissions, :roles => :passenger_nginx do
      rsudo "chown #{rubber_env.app_user}:#{rubber_env.app_user} #{current_path}/config/environment.rb"
    end
    
    on :load do
      rubber.serial_task self, :serial_restart, :roles => :passenger_nginx do
        rsudo "service nginx restart"
      end
      rubber.serial_task self, :serial_reload, :roles => :passenger_nginx do
        rsudo "if ! ps ax | grep -v grep | grep -c nginx &> /dev/null; then service nginx start; else service nginx reload; fi"
      end
    end

    # Curious: ensure that the nginx logs directory exists after stopping/restarting an instance
    # See https://groups.google.com/d/msg/rubber-ec2/mUuFMmAobAo/2smRWj3s1fAJ
    after "rubber:bootstrap", "rubber:passenger_nginx:bootstrap"

    task :bootstrap, :roles => :passenger_nginx do
      rsudo "mkdir -p #{rubber_env.nginx_log_dir}"
    end    

    before "deploy:stop", "rubber:passenger_nginx:stop"
    after "deploy:start", "rubber:passenger_nginx:start"
    after "deploy:restart", "rubber:passenger_nginx:reload"
    
    # Curious: after restarting passenger, hit it once to warm it up, otherwise the first
    # request from an actual customer may cause timeouts.
    after "rubber:passenger_nginx:start", "rubber:passenger_nginx:warmup"
    after "rubber:passenger_nginx:reload", "rubber:passenger_nginx:warmup"

    desc "Stops the nginx web server"
    task :stop, :roles => :passenger_nginx do
      rsudo "service nginx stop; exit 0"
    end
    
    desc "Starts the nginx web server"
    task :start, :roles => :passenger_nginx do
      rsudo "service nginx status || service nginx start"
    end
    
    desc "Restarts the nginx web server"
    task :restart, :roles => :passenger_nginx do
      serial_restart
    end
  
    desc "Reloads the nginx web server"
    task :reload, :roles => :passenger_nginx do
      serial_reload
    end

    # Curious: after restarting passenger, hit it once to warm it up, otherwise the first
    # request from an actual customer may cause timeouts.
    desc "Warms up passenger to start taking traffic immediately"
    task :warmup, :roles => :passenger_nginx do
      # -u option (username/password) is only required due to our use of HTTP basic auth to secure qa/exdev
      # -m 300 tells curl to wait no more than 5min before giving up
      rsudo "curl -s -u fun:cocoa -m 300 'http://localhost:#{rubber_env.passenger_listen_port}/' &> /dev/null; exit 0"
    end
    
    
    deploy.task :restart, :roles => :passenger_nginx do
    end
    
    deploy.task :reload, :roles => :passenger_nginx do
    end
    
    deploy.task :stop, :roles => :passenger_nginx do
    end
    
    deploy.task :start, :roles => :passenger_nginx do
    end
    
  end
end
