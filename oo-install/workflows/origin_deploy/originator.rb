#!/usr/bin/env ruby

require 'yaml'
require 'net/ssh'

CONFIG_FILE = ENV['HOME'] + '/.openshift/oo-install-cfg.yml'
SOCKET_IP_ADDR = 3
VALID_IP_ADDR_RE = Regexp.new('^(?:(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$')

# This is a -very- simple way of making sure we don't inadvertently
# use a multicast IP addr or subnet mask. There's room for
# improvement here.
def find_good_ip_addr list
  list.each do |addr|
    triplets = addr.split('.')
    if not triplets[0].to_i == 255 and not triplets[2].to_i == 255
      return addr
    end
  end
  nil
end

@tmpdir = ENV['TMPDIR'] || '/tmp'
if @tmpdir.end_with?('/')
  @tmpdir = @tmpdir.chop
end

# If this is the add-a-node scenario, the node to be installed will
# be passed via the command line
@target_node_index = ARGV[0].nil? ? nil : ARGV[0].split('::')[1].to_i
@target_node_host = nil

# Default and baked-in config values for the Puppet deployment
@puppet_map = { 'roles' => ['broker','activemq','datastore','named'] }

# These values will be set in a Puppet config file
@env_input_map = {
  'subscription_type' => ['install_method'],
  'repos_base' => ['repos_base'],
  'os_repo' => ['os_repo'],
  'jboss_repo_base' => ['jboss_repo_base'],
  'os_optional_repo' => ['optional_repo'],
}

# Pull values that may have been passed on the command line into the launcher
@env_input_map.each_pair do |input,target_list|
  env_key = "OO_INSTALL_#{input.upcase}"
  if ENV.has_key?(env_key)
    target_list.each do |target|
      @puppet_map[target] = ENV[env_key]
    end
  end
end

@utility_install_order = ['named','datastore','activemq','broker','node']

# Maps openshift.sh roles to oo-install deployment components
@role_map =
{ 'named' => { 'deploy_list' => 'Brokers', 'role' => 'broker', 'env_var' => 'named_hostname' },
  'broker' => { 'deploy_list' => 'Brokers', 'role' => 'broker', 'env_var' => 'broker_hostname' },
  'node' => { 'deploy_list' => 'Nodes', 'role' => 'node', 'env_var' => 'node_hostname' },
  'activemq' => { 'deploy_list' => 'MsgServers', 'role' => 'mqserver', 'env_var' => 'activemq_hostname' },
  'datastore' => { 'deploy_list' => 'DBServers', 'role' => 'dbserver', 'env_var' => 'datastore_hostname' },
}

# Will map hosts to roles
@hosts = {}

config = YAML.load_file(CONFIG_FILE)

# Set values from deployment configuration
if config.has_key?('Deployment')
  @deployment_cfg = config['Deployment']

  # First, make a host map and a complete env map
  @role_map.keys.each do |role|
    # We only support multiple nodes; bail if we have multiple host instances for other roles.
    if not role == 'node' and @deployment_cfg[@role_map[role]['deploy_list']].length > 1
      puts "This workflow can only handle deployments containing a single #{role}. Exiting."
      exit 1
    end

    for idx in 0..(@deployment_cfg[@role_map[role]['deploy_list']].length - 1)
      host_instance = @deployment_cfg[@role_map[role]['deploy_list']][idx]
      if role == 'node' and @target_node_index == idx
        @target_node_host = host_instance['ssh_host']
      end
      # The host map helps us sanity check and call Puppet jobs
      if not @hosts.has_key?(host_instance['ssh_host'])
        @hosts[host_instance['ssh_host']] = { 'roles' => [], 'username' => host_instance['user'], 'host' => host_instance['host'] }
      end
      @hosts[host_instance['ssh_host']]['roles'] << role

      # The env map is passed to each job, but nodes are handled individually
      if not role == 'node'
        @puppet_map[@role_map[role]['env_var']] = host_instance['host']
        if role == 'named' and @puppet_map['named_ip_addr'].nil?
          # Try to look up the IP address of the Broker host to set the named IP address
          ip_lookup_command = '/usr/sbin/ip addr show eth0 | grep \'inet \''
          if not host_instance['ssh_host'] == 'localhost'
            ip_lookup_command = "ssh #{host_instance['user']}@#{host_instance['ssh_host']} \"#{ip_lookup_command}\""
          end
          ip_text = %x[ #{ip_lookup_command} ].chomp
          ip_addrs = ip_text.split(/[\s\:\/]/).select{ |v| v.match(VALID_IP_ADDR_RE) }
          good_addr = find_good_ip_addr ip_addrs
          if good_addr.nil?
            puts "Could not determine a broker IP address for named. Trying socket lookup from this machine."
            socket_info = nil
            begin
              socket_info = Socket.getaddrinfo(host_instance['host'], 'ssh')
            rescue SocketError => e
              puts "Socket lookup of broker IP address failed. The installation cannot continue."
              exit
            end
            @puppet_map['named_ip_addr'] = socket_info[0][SOCKET_IP_ADDR]
          else
            @puppet_map['named_ip_addr'] = good_addr
          end
        end
      end
    end
  end
  @puppet_map['domain'] = @deployment_cfg['DNS']['app_domain']
end

if @hosts.empty?
  puts "The config file at #{CONFIG_FILE} does not contain OpenShift deployment information. Exiting."
  exit 1
end

if not @target_node_index.nil? and @target_node_host.nil?
  puts "The list of nodes in the config file at #{CONFIG_FILE} is shorter than the index of the specified node host to be installed. Exiting."
  exit 1
end

# Make sure the per-host config is legit
@hosts.each_pair do |ssh_host,info|
  roles = info['roles']
  duplicate = roles.detect{ |e| roles.count(e) > 1 }
  if not duplicate.nil?
    puts "Multiple instances of role type '#{@role_map[duplicate]['role']}' are specified for installation on the same target host (#{ssh_host}).\nThis is not a valid configuration. Exiting."
    exit 1
  end
  if not @target_node_host.nil? and @target_node_host == ssh_host and (roles.length > 1 or not roles[0] == 'node')
    puts "The specified node to be added also contains other OpenShift components.\nNodes can only be added as standalone components on their own systems. Exiting."
    exit 1
  end
end

# Set the installation order
host_order = []
@utility_install_order.each do |role|
  if not role == 'node' and not @target_node_host.nil?
    next
  end
  @hosts.select{ |key,hash| hash['roles'].include?(role) }.each do |matched_host|
    ssh_host = matched_host[0]
    if not @target_node_host.nil? and not @target_node_host == ssh_host
      next
    end
    if not host_order.include?(ssh_host)
      host_order << ssh_host
    end
  end
end

# Summarize the plan
if @target_node_host.nil?
  puts "Preparing to install OpenShift Origin on the following hosts:\n"
else
  puts "Preparing to add this node to an OpenShift Origin system:\n"
end
host_order.each do |ssh_host|
  puts "  * #{ssh_host}: #{@hosts[ssh_host]['roles'].join(', ')}\n"
end

# Make it so
host_order.each do |ssh_host|
  user = @hosts[ssh_host]['username']
  host = @hosts[ssh_host]['host']
  @puppet_map['roles'] = "[" + @hosts[ssh_host]['roles'].map{ |r| "'#{r}'" }.join(',') + "]"

  # Only include the node config setting for hosts that will have a node installation
  if @hosts[ssh_host]['roles'].include?('node')
    @puppet_map[@role_map['node']['env_var']] = @hosts[ssh_host]['host']
  else
    @puppet_map.delete(@role_map['node']['env_var'])
  end

  # Make a puppet config file for this host.
  filetext = "class { 'openshift_origin' :\n"
  @puppet_map.each_pair do |key,val|
    valtxt = key == 'roles' ? val : "'#{val}'"
    filetext << "  #{key} => #{valtxt},\n"
  end
  filetext << "}\n"

  # Write it out so we can copy it to targets
  hostfile = "oo_install_configure_#{host}.pp"
  hostfilepath = "#{@tmpdir}/#{hostfile}"
  if File.exists?(hostfilepath)
    File.unlink(hostfilepath)
  end
  fh = File.new(hostfilepath, 'w')
  fh.write(filetext)
  fh.close
  exit # TEST

  if not ssh_host == 'localhost'
    puts "Copying Puppet configuration script to target #{ssh_host}.\n"
    system "scp #{hostfilepath} #{user}@#{ssh_host}:~/"
  end
  puts "Running deployment\n"
  command_parts = [
    'puppet module install --force openshift/openshift_origin',
    "puppet apply --verbose ~/#{hostfile}",
    "rm ~/#{hostfile}",
    'reboot',
  ]
  if not user == 'root'
    [0,1,3].each do |idx|
      command_parts[idx] = "sudo #{command_parts[idx]}"
    end
  end
  puppet_command = command_parts.join(' \&\& ')
  if not ssh_host == 'localhost'
    puppet_command = "ssh #{user}@#{ssh_host} '#{puppet_command}'"
  end
  if system(puppet_command)
    puts "Installation on target #{ssh_host} completed.\n"
  else
    puts "Error installing OpenShift on target #{ssh_host}. Exiting.\n"
    exit 1
  end
end

puts "OpenShift Origin deployment completed."
exit