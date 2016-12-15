#
# Cookbook Name:: cerny_proxmox
# Recipe:: default
#
# Copyright 2016 Nathan Cerny
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
# rubocop:disable LineLength

template '/etc/network/interfaces' do
  source 'interfaces.erb'
  variables copper_interfaces: 'eth0 eth1 eth2 eth3',
            optical_interfaces: 'eth4',
            cluster_interface: 'eth5',
            ip: "1#{node['hostname'][-1]}"
end

apt_repository 'pve-enterprise' do
  action :remove
end

include_recipe 'chef-apt-docker'

apt_repository 'pve-no-subscription' do
  uri 'http://download.proxmox.com/debian'
  distribution node['lsb']['codename'] || 'jessie'
  components ['pve-no-subscription']
  notifies :update, 'apt_update[pve]', :immediately
end

apt_repository 'glusterfs' do
  uri 'http://download.gluster.org/pub/gluster/glusterfs/3.9/LATEST/Debian/jessie/apt'
  distribution node['lsb']['codename'] || 'jessie'
  components ['main']
  key 'http://download.gluster.org/pub/gluster/glusterfs/3.9/rsa.pub'
  notifies :update, 'apt_update[pve]', :immediately
end

apt_repository 'jessie-backports' do
  uri 'http://ftp.debian.org/debian'
  distribution 'jessie-backports'
  components ['main']
  notifies :update, 'apt_update[pve]', :immediately
  action :remove
end

apt_update 'pve' do
  action :periodic
  frequency 86_400
  notifies :run, 'execute[dist-upgrade]', :immediately
end

file '/etc/apt/apt.conf.d/15update-stamp' do
  content 'APT::Update::Post-Invoke-Success {"touch /var/lib/apt/periodic/update-success-stamp 2>/dev/null || true";};'
end

execute 'dist-upgrade' do
  action :nothing
  command 'apt-get -y dist-upgrade'
  notifies :reboot_now, 'reboot[reboot-for-upgrades]', :immediately
  not_if do
    ::File.exist?('/etc/apt/apt.conf.d/15update-stamp') &&
      (::DateTime.now - ::File.mtime('/etc/apt/apt.conf.d/15update-stamp')).to_i <= 7
  end
  only_if { ::Date.today.wday.eql?(node['hostname'][-2, 2].to_i % 7) }
end

reboot 'reboot-for-upgrades' do
  action :nothing
  only_if { reboot_pending? }
end

execute 'join proxmox cluster' do
  if node['hostname'].eql?('pve01')
    command 'pvecm create proxmox -bindnet0_addr 172.16.40.11 -ring0_addr 172.16.40.11'
  else
    command "pvecm add 172.16.40.11 -nodeid #{node['hostname'][-1]} -ring0_addr 172.16.40.1#{node['hostname'][-1]}"
  end
  not_if { ::File.exist?('/etc/pve/corosync.conf') }
end

%w(lsb-release glusterfs-server glusterfs-client).each do |pkg|
  package pkg
end

include_recipe 'lvm::default'

# VM Disks
pve_pvs = []
node['block_device'].each do |drive, props|
  pve_pvs << "/dev/#{drive}" if props['model'].eql?('MK3001GRRB')
end

lvm_volume_group 'pvedata' do
  physical_volumes pve_pvs
  wipe_signatures true

  logical_volume 'data' do
    size        '99%VG'
    filesystem  'xfs'
    mount_point location: '/var/lib/vz'
  end
end

# GlusterFS Disks
gluster_pvs = []
node['block_device'].each do |drive, props|
  gluster_pvs << "/dev/#{drive}" if props['model'].eql?('MBF2600RC')
end
unless gluster_pvs.empty?
  directory '/export/gv0' do
    recursive true
  end

  lvm_volume_group 'glusterfs' do
    physical_volumes gluster_pvs
    wipe_signatures true

    logical_volume 'gv0' do
      size        '99%VG'
      filesystem  'xfs'
      mount_point location: '/export/gv0'
      stripes     2
    end
  end

  directory '/export/gv0/brick'

  gluster_hosts = %w(pve01.infra.cerny.cc pve02.infra.cerny.cc)
  gluster_hosts.each do |host|
    execute "GlusterFS: Configure the Trusted Pool - #{host}" do
      command "gluster peer probe #{host}"
      not_if { node['fqdn'].eql?(host) }
      not_if "gluster peer status | grep #{host}"
    end
  end

  bricks = ''
  gluster_hosts.each do |host|
    bricks << "#{host}:/export/gv0/brick "
  end

  # setfattr -x trusted.glusterfs.volume-id /export/gv0/brick
  # setfattr -x trusted.gfid /export/gv0/brick

  execute 'GlusterFS: Create Volume gv0' do
    command "gluster volume create gv0 replica #{gluster_hosts.count} #{bricks}"
    not_if 'gluster volume status gv0'
  end

  execute 'GlusterFS: Start volume gv0' do
    command 'gluster volume start gv0'
    not_if 'gluster volume info gv0 | grep Status | grep Started'
  end
end

execute 'PVE: Remove default storage - local-lvm' do
  command 'pvesh delete /storage/local-lvm'
  only_if 'pvesh get /storage/local-lvm'
end

execute 'PVE: Configure local storage' do
  command 'pvesh set /storage/local -content iso,vztmpl,rootdir,images'
  not_if 'pvesh get /storage/local | grep "iso,vztmpl,rootdir,images"'
end

execute 'PVE: Configure GlusterFS Storage' do
  command 'pvesh create /storage -storage gluster -type glusterfs -content images,iso,vztmpl -server pve01.infra.cerny.cc -server2 pve02.infra.cerny.cc -transport tcp -volume gv0'
  not_if 'pvesh get /storage/gluster'
end

# pve_cloud_template 'TEMPLATE: Centos 7 (1608)' do
#   vmid 950
#   src 'http://cloud.centos.org/centos/7/images/CentOS-7-x86_64-GenericCloud-1608.qcow2'
#   checksum 'b56ed1a3a489733d3ff91aca2011f8720c0540b9aa27e46dd0b4f575318dd1fa'
#   host 'pve01'
# end
#
# pve_cloud_template 'TEMPLATE: Ubuntu 16.04 (20161205)' do
#   vmid 960
#   src 'http://cloud-images.ubuntu.com/releases/16.04/release-20161205/ubuntu-16.04-server-cloudimg-amd64-disk1.img'
#   checksum 'b9ae0b87aa4bd6539aa9b509278fabead3fe86aa3d615f02b300c72828bcfaad'
#   host 'pve01'
# end

{
  'centos-7-default' => :system,
  'ubuntu-14.04-standard' => :system,
  'ubuntu-16.04-standard' => :system
}.each do |fn, src|
  if src.is_a?(String)
    remote_file fn do
      source src
      not_if "pvesh get /nodes/#{node['hostname']}/storage/gluster/content | grep #{fn}"
      notifies :run, "execute[GlusterFS: Upload #{fn}]", :immediately
    end
    execute "GlusterFS: Upload #{fn}" do
      command "pvesh create /nodes/#{node['hostname']}/storage/gluster/upload -content iso -filename #{fn} -tmpfilename #{fn}"
      action :nothing
    end
  elsif src.is_a?(Symbol)
    vztmpl = {}
    Mixlib::ShellOut.new('pveam available').run_command.stdout.each_line do |line|
      line = line.split
      vztmpl[line[0]] ||= []
      vztmpl[line[0]] << line[1]
    end

    vztmpl[src.to_s].select { |n| n =~ /#{fn}/ }.each do |f|
      execute "GlusterFS: Upload #{f}" do
        command "pveam download gluster #{f}"
        not_if "pvesh get /nodes/#{node['hostname']}/storage/gluster/content | grep #{f}"
      end
    end
  end
end

docker_service 'default' do
  host ['unix:///var/run/docker.sock']
  install_method 'package'
  action [:create, :start]
end

%w(acceptance union rehearsal delivered).each do |pool|
  execute "PVE: Create pool #{pool}" do
    command "pvesh create /pools -poolid #{pool}"
    not_if "pvesh get /pools/#{pool}"
  end
end

%w(chef-server chef-backend).each do |d|
  directory "/etc/pve/chef/#{d}" do
    recursive true
  end
end

execute "CT: Create chefbe#{node['hostname'][-2,2]}" do
  command "pvesh create /nodes/#{node['hostname']}/lxc -ostemplate gluster:vztmpl/ubuntu-16.04-standard_16.04-1_amd64.tar.gz -vmid 90#{node['hostname'][-1]}"
  not_if "pvesh get /nodes/#{node['hostname']}/lxc/90#{node['hostname'][-1]}"
end

execute "CT: Configure chefbe#{node['hostname'][-2,2]}" do
  command "pvesh set /nodes/#{node['hostname']}/lxc/90#{node['hostname'][-1]}/config \
            -hostname chefbe#{node['hostname'][-2,2]}delivered.cerny.cc \
            -cores 2 \
            -memory 4096 \
            -net0 name=eth0,bridge=vmbr1,type=veth \
            -mp0 /etc/pve/chef/chef-backend,mp=/etc/chef-backend \
            -onboot 1"
  only_if "pct status 90#{node['hostname'][-1]} | grep stopped"
end

execute "CT: Create cheffe#{node['hostname'][-2,2]}" do
  command "pvesh create /nodes/#{node['hostname']}/lxc -ostemplate gluster:vztmpl/ubuntu-16.04-standard_16.04-1_amd64.tar.gz -vmid 90#{(3 + node['hostname'][-1].to_i)}"
  not_if "pvesh get /nodes/#{node['hostname']}/lxc/90#{(3 + node['hostname'][-1].to_i)}"
end

execute "CT: Configure cheffe#{node['hostname'][-2,2]}" do
  command "pvesh set /nodes/#{node['hostname']}/lxc/90#{(3 + node['hostname'][-1].to_i)}/config \
            -hostname cheffe#{node['hostname'][-2,2]}delivered.cerny.cc \
            -cores 2 \
            -memory 4096 \
            -net0 name=eth0,bridge=vmbr1,type=veth \
            -mp0 /etc/pve/chef/chef-server,mp=/etc/opscode \
            -onboot 1"
  only_if "pct status 90#{(3 + node['hostname'][-1].to_i)} | grep stopped"
end

execute "CT: Set chefbe#{node['hostname'][-2,2]} to Delivered pool" do
  command "pvesh set /pools/delivered -vms 90#{node['hostname'][-1]}"
end

execute "CT: Set cheffe#{node['hostname'][-2,2]} to Delivered pool" do
  command "pvesh set /pools/delivered -vms 90#{(3 + node['hostname'][-1].to_i)}"
end

execute "CT: Start chefbe#{node['hostname'][-2,2]}" do
  command "pct start 90#{node['hostname'][-1]}"
  only_if "pct status 90#{node['hostname'][-1]} | grep stopped"
end

execute "CT: Start cheffe#{node['hostname'][-2,2]}" do
  command "pct start 90#{(3 + node['hostname'][-1].to_i)}"
  only_if "pct status 90#{(3 + node['hostname'][-1].to_i)} | grep stopped"
end

remote_file 'chef-backend' do
  source 'https://packages.chef.io/files/stable/chef-backend/1.2.5/ubuntu/16.04/chef-backend_1.2.5-1_amd64.deb'
  checksum '3bbef404313852440ee511e6a1711afb69c4a3d48314d6efb35884a400373b5f'
  notifies :run, 'execute[CT: Push chef-backend package]', :immediately
end

remote_file 'chef-server-core' do
  source 'https://packages.chef.io/files/stable/chef-server/12.11.1/ubuntu/16.04/chef-server-core_12.11.1-1_amd64.deb'
  checksum 'f9937ae1f43d7b5b12a5f91814c61ce903329197cd342228f2a2640517c185a6'
  notifies :run, 'execute[CT: Push chef-server-core package]', :immediately
end

execute 'CT: Push chef-backend package' do
  action :nothing
  command "pct push 90#{node['hostname'][-1]} chef-backend_1.2.5-1_amd64.deb /tmp/chef-backend_1.2.5-1_amd64.deb"
  notifies :run, 'execute[CT: Install chef-backend]', :immediately
end

execute 'CT: Push chef-server-core package' do
  action :nothing
  command "pct push 90#{(3 + node['hostname'][-1].to_i)} chef-server-core_12.11.1-1_amd64.deb /tmp/chef-server-core_12.11.1-1_amd64.deb"
  notifies :run, 'execute[CT: Install chef-server-core]', :immediately
end

execute 'CT: Install chef-backend' do
  action :nothing
  command "pct exec 90#{node['hostname'][-1]} -- dpkg -i /tmp/chef-backend_1.2.5-1_amd64.deb"
end

execute 'CT: Install chef-server-core' do
  action :nothing
  command "pct exec 90#{(3 + node['hostname'][-1].to_i)} -- dpkg -i /tmp/chef-server-core_12.11.1-1_amd64.deb"
end

execute 'CT: Create Cluster' do
  command "pct exec 90#{node['hostname'][-1]} -- chef-backend-ctl create-cluster"
  not_if { ::File.exist?('/etc/pve/chef/chef-backend/chef-backend-secrets.json') }
  not_if "pct exec 90#{node['hostname'][-1]} -- chef-backend-ctl status"
end

execute 'CT: Join Cluster' do
  command "pct exec 90#{node['hostname'][-1]} -- chef-backend-ctl create-cluster"
  only_if { ::File.exist?('/etc/pve/chef/chef-backend/chef-backend-secrets.json') }
  not_if "pct exec 90#{node['hostname'][-1]} -- chef-backend-ctl status"
end

execute 'CT: Create chef-server.rb' do
  command "pct exec 90#{node['hostname'][-1]} -- chef-backend-ctl gen-server-config chef.cerny.cc -f /tmp/chef-server.rb"
  not_if { ::File.exist?('/etc/pve/chef/chef-server/chef-server.rb') }
end

execute 'CT: Pull chef-server.rb' do
  command "pct pull 90#{node['hostname'][-1]} /tmp/chef-server.rb /etc/pve/chef/chef-server/chef-server.rb"
  not_if { ::File.exist?('/etc/pve/chef/chef-server/chef-server.rb') }
  notifies :run, 'execute[CT: chef-server-ctl reconfigure]', :immediately
end

execute 'CT: chef-server-ctl reconfigure' do
  command "pct exec 90#{(3 + node['hostname'][-1].to_i)} -- chef-server-ctl reconfigure"
  action :nothing
end

# Pull latest image
# docker_image 'haproxy' do
#   tag 'latest'
#   action :pull
#   notifies :redeploy, 'docker_container[lb_haproxy]'
# end
#
# directory '/etc/haproxy'
#
# cookbook_file '/etc/haproxy/haproxy.cfg' do
#   source 'haproxy.cfg'
# end

# Run container exposing ports
# docker_container 'lb_haproxy' do
#   repo 'haproxy'
#   tag 'latest'
#   port ['80:80', '443:443']
#   host_name "haproxy#{node['hostname'][-2]}"
#   domain_name 'infra.cerny.cc'
#   volumes ['/etc/haproxy/haproxy.cfg:/usr/local/etc/haproxy/haproxy.cfg:ro']
# end

# git 'acme.sh' do
#   repository 'https://github.com/Neilpang/acme.sh.git'
#   revision 'master'
#   destination '/root/acme.sh-master'
#   action :sync
#   notifies :run, 'execute[acme.sh-install]', :immediately
# end
#
# directory '/etc/pve/.le'
#
# execute 'acme.sh-install' do
#   command './acme.sh --install --accountconf /etc/pve/.le/account.conf --accountkey /etc/pve/.le/account.key --accountemail ncerny@gmail.com'
#   cwd '/root/acme.sh-master'
#   action :nothing
# end
#
# execute 'acme.sh issue-certificate' do
#   command <<-EOF
#     ./acme.sh --issue --standalone --keypath /etc/pve/local/pveproxy-ssl.key \
#       --fullchainpath /etc/pve/local/pveproxy-ssl.pem \
#       --reloadcmd "systemctl restart pveproxy" \
#       -d #{node['fqdn']}
#     EOF
#   cwd '/root/.acme.sh'
# end

# Ceph Cache Disks
# TXA2D20400GA6001

#
#
#
# fdisk -u /dev/sdd
#
#
# pvcreate /dev/sdd1
# vgcreate pvedata /dev/sdd1
# lvcreate -n data -L 400G pvedata
# mkfs.xfs -i size=512 /dev/pvedata/data
#
#
# vi /etc/fstab
#
#
# umount /var/lib/vz && mount -a
