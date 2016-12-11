# rubocop:disable LineLength
require_relative '../libraries/api'
include Proxmox::API

resource_name 'pve_vm'
default_action :start

property :name, String, name_property: true
property :vmid, String, default: nil
property :clone, String, default: nil
property :full_copy, [TrueClass, FalseClass], default: true
property :host, String, default: node['hostname']
property :size, [String, Hash], default: 'micro'
property :net, Hash, default: { net0: 'virtio,bridge=vmbr0' }
property :numa, [TrueClass, FalseClass], default: true
property :hugepages, ['any', '2', '1024', false], default: false
property :ostype, String, default: 'linux'
property :disk, String, default: '32G'
property :storage, String, default: 'local'
property :cdrom, String, default: 'none'
property :cloud_init, String
property :template, [TrueClass, FalseClass], default: false

attr_reader :status

alias os ostype
alias init cloud_init

api = Proxmox::API.new

INSTANCE_SIZE = {
  'nano'    => { cpu: 1,  mem: 0.5 * 1024 },
  'micro'   => { cpu: 1,  mem: 1   * 1024 },
  'small'   => { cpu: 1,  mem: 2   * 1024 },
  'medium'  => { cpu: 2,  mem: 4   * 1024 },
  'large'   => { cpu: 2,  mem: 8   * 1024 },
  'xlarge'  => { cpu: 4,  mem: 16  * 1024 },
  '2xlarge' => { cpu: 8,  mem: 32  * 1024 },
  '4xlarge' => { cpu: 16, mem: 64  * 1024 }
}.freeze

OS_TYPE = {
  'other'   => 'other', # Unspecified OS
  'l26'     => %w(linux l26 linux26 linux3 linux4), # Linux 2.6/3.X/4.X Kernel
  'wxp'     => %w(wxp winxp), # Microsoft Windows XP
  'w2k8'    => %w(w2k8 win2008 win2k8 w2k8r2 win2008r2 win2k8r2), # Microsoft Windows 2008
  'win7'    => 'win7', # Microsoft Windows 7
  'win8'    => %w(win8 win2012), # Microsoft Windows 8/2012
  'win10'   => %w(windows win10 win2016), # Microsoft Windows 10/2016
  'solaris' => %w(solaris opensolaris openindiana) # Solaris / OpenSolaris / OpenIndiana Kernel
}.freeze

load_current_value do
  res = api.get('/cluster/resources', type: 'vm')
  res.each do |resource|
    next unless resource['name'].eql?(name)
    vmid resource['vmid']
    config = api.get("/nodes/#{resource['host']}/qemu/#{vmid}/config")
    name resource['name']
    host resource['node']
    disk resource['maxdisk']
    template (resource['template'].eql?(1) ? true : false) # rubocop:disable ParenthesesAsGroupedExpression
    status resource['status']
    size get_size(config['cores'], config['memory'])
    net config.select { |k, _| k.to_s.start_with?('net') }
    numa config['numa']
    hugepages config['hugepages']
    ostype get_ostype(config['ostype'])
  end
end

def vmid
  new_resource.vmid || current_resource.vmid || api.nextid
end

# rubocop:disable MethodLength
# rubocop:disable AbcSize
def create_vm
  if new_resource.clone
    clone_vm
  else
    data = {
      vmid: vmid,
      bootdisk: 'virtio0',
      cores: INSTANCE_SIZE[new_resource.size]['cpu'],
      memory: INSTANCE_SIZE[new_resource.size]['memory'],
      ide2: "#{new_resource.cdrom},media=cdrom",
      numa: (new_resource.numa ? 1 : 0),
      ostype: get_type(new_resource.ostype),
      sockets: 1,
      virtio0: "#{new_resource.storage}:/vm-#{vmid}-disk-1.qcow2,size=#{new_resource.disk}"
    }.merge(new_resource.net)
    data.merge(hugepages: new_resource.hugepages) if new_resource.hugepages
    api.post("/nodes/#{new_resource.host}/qemu", data)
  end
end

def clone_vm
  res = api.get('/cluster/resources', type: 'vm')
  res.each do |resource|
    next unless resource['vmid'].eql?(new_resource.clone)
    data = {
      newid: vmid,
      format: 'qcow2',
      full: (new_resource.full_copy ? 1 : 0),
      name: new_resource.name,
      storage: new_resource.storage,
      target: new_resource.host
    }
    api.post("/nodes/#{resource['node']}/qemu/#{new_resource.clone}/clone", data)
  end
end

action :create do
  create_vm
end

action :start do
  create_vm
  if current_resource.host && current_resource.host != new_resource.host
    api.post("/nodes/#{current_resource.host}/qemu/#{vmid}/migrate", target: new_resource.host, online: (current_resource.status.eql?('running') ? 1 : 0))
  end
  api.post("/nodes/#{new_resource.host}/qemu/#{vmid}/status/start") unless current_resource.status.eql?('running')
end

action :enable do
  create_vm
  api.post("/nodes/#{new_resource.host}/qemu/#{vmid}/config", onboot: 1)
end

def get_size(cpu, mem)
  INSTANCE_SIZE.key(cpu: cpu, mem: mem) || { custom: { cpu: cpu, mem: mem } }
end

def get_type(type)
  OS_TYPE.select { |_, v| v.include?(type.downcase) }
end
