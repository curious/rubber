<%
  @path = "/etc/profile.d/rubber.sh"
  current_path = "/mnt/#{rubber_env.app_name}-#{Rubber.env}/current" 
%>

# convenience to simply running rails console, etc with correct env
export RUBBER_ENV=<%= Rubber.env %>
export RAILS_ENV=<%= Rubber.env %>
alias current="cd <%= current_path %>"
alias release="cd <%= Rubber.root %>"

# Curious: Tune Ruby garbage collector using the settings recommended by Twitter.
# See http://www.web-l.nl/posts/15-tuning-ruby-s-garbage-collector-with-rvm-and-passenger
# See http://www.rubyenterpriseedition.com/documentation.html
#
#   "Twitter’s settings mean:
#
#    * Start with enough memory to hold the application (Ruby’s default is very low, 
#      lower than what a Rails application typically needs).
#    * Increase it linearly if you need more (Ruby’s default is exponential increase).
#    * Only garbage-collect every 50 million malloc calls (Ruby’s default is 6x smaller)."
#
#    Twitter claims that these settings give them about 20% to 40% average performance 
#    improvement, at the cost of slightly higher peak memory usage."
#
export RUBY_HEAP_SLOTS_INCREMENT=250000
export RUBY_HEAP_SLOTS_GROWTH_FACTOR=1
export RUBY_GC_HEAP_INIT_SLOTS=500000
export RUBY_GC_MALLOC_LIMIT=50000000
