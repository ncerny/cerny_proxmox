# rubocop:disable LineLength

class Proxmox
  class API
    # def initialize()
    #
    # end

    def send_pvesh_request(method, path, data = {})
      cmd = Mixlib::ShellOut.new("pvesh #{method} #{path} #{data.map { |k, v| " -#{k} #{v}" }.join}")
      begin
        JSON.parse(cmd.run_command.stdout)
      rescue
        cmd.stdout
      end
    end

    def get(path, data = {})
      send_pvesh_request('get', path, data)
    end

    def post(path, data = {})
      send_pvesh_request('create', path, data)
    end

    def create(path, data = {})
      send_pvesh_request('create', path, data)
    end

    def put(path, data = {})
      send_pvesh_request('set', path, data)
    end

    def set(path, data = {})
      send_pvesh_request('set', path, data)
    end

    def delete(path, data = {})
      send_pvesh_request('delete', path, data)
    end

    def nextid
      send_pvesh_request('get', '/cluster/nextid')[/[^"]+/]
    end
  end
end
