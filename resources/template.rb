require_relative '../libraries/api'

resource_name 'pve_cloud_template'

property :name, String, name_property: true
property :vmid, String, default: nil
property :host, String, default: node['hostname']
property :size, [String, Hash], default: 'micro'
property :net, Hash, default: { net0: 'virtio,bridge=vmbr0' }
property :numa, [TrueClass, FalseClass], default: true
property :hugepages, ['any', '2', '1024', false], default: false
property :ostype, String, default: 'linux'
property :disk, String, default: '32G'
property :image_src, String, required: true
property :checksum, String
property :storage, String, default: 'local'

alias os ostype
alias image image_src
alias src image_src

api = Proxmox::API.new

def vmid
  new_resource.vmid || current_resource.vmid || api.nextid
end

action :create do
  id = vmid
  base_path = api.get(new_resource.storage)['path']

  directory "#{base_path}/images/#{id}"

  remote_file "#{base_path}/images/#{id}/vm-#{id}-disk-1.qcow2" do
    source new_resource.image_src
    checksum new_resource.checksum
  end

  proxmox_vm new_resource.name do
    action :create
    vmid id
    host new_resource.host
    size new_resource.size
    net new_resource.net
    numa new_resource.numa
    hugepages new_resource.hugepages
    ostype new_resource.ostype
    disk new_resource.disk
    storage new_resource.storage
    template true
  end
end
