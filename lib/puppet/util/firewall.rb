# frozen_string_literal: true

require 'socket'
require 'resolv'
require 'puppet/util/ipcidr'

# Util module for puppetlabs-firewall
module Puppet::Util::Firewall
  # Translate the symbolic names for icmp packet types to integers
  def icmp_name_to_number(value_icmp, protocol)
    if %r{\d{1,2}$}.match?(value_icmp)
      value_icmp
    elsif protocol == 'inet'
      case value_icmp
      when 'echo-reply' then '0'
      when 'destination-unreachable' then '3'
      when 'source-quench' then '4'
      when 'redirect' then '6'
      when 'echo-request' then '8'
      when 'router-advertisement' then '9'
      when 'router-solicitation' then '10'
      when 'time-exceeded' then '11'
      when 'parameter-problem' then '12'
      when 'timestamp-request' then '13'
      when 'timestamp-reply' then '14'
      when 'address-mask-request' then '17'
      when 'address-mask-reply' then '18'
      else nil
      end
    elsif protocol == 'inet6'
      case value_icmp
      when 'destination-unreachable' then '1'
      when 'too-big' then '2'
      when 'time-exceeded' then '3'
      when 'parameter-problem' then '4'
      when 'echo-request' then '128'
      when 'echo-reply' then '129'
      when 'router-solicitation' then '133'
      when 'router-advertisement' then '134'
      when 'neighbour-solicitation' then '135'
      when 'neighbour-advertisement' then '136'
      when 'redirect' then '137'
      else nil
      end
    else
      raise ArgumentError, "unsupported protocol family '#{protocol}'"
    end
  end

  # Convert log_level names to their respective numbers
  def log_level_name_to_number(value)
    if %r{\A[0-7]\z}.match?(value)
      value
    else
      case value
      when 'panic' then '0'
      when 'alert' then '1'
      when 'crit' then '2'
      when 'err' then '3'
      when 'error' then '3'
      when 'warn' then '4'
      when 'warning' then '4'
      when 'not' then '5'
      when 'notice' then '5'
      when 'info' then '6'
      when 'debug' then '7'
      else nil
      end
    end
  end

  # This method takes a string and a protocol and attempts to convert
  # it to a port number if valid.
  #
  # If the string already contains a port number or perhaps a range of ports
  # in the format 22:1000 for example, it simply returns the string and does
  # nothing.
  def string_to_port(value, proto)
    proto = proto.to_s
    unless %r{^(tcp|udp)$}.match?(proto)
      proto = 'tcp'
    end

    m = value.to_s.match(%r{^(!\s+)?(\S+)})
    return "#{m[1]}#{m[2]}" if %r{^\d+(-\d+)?$}.match?(m[2])
    "#{m[1]}#{Socket.getservbyname(m[2], proto)}"
  end

  # Takes an address and protocol and returns the address in CIDR notation.
  #
  # The protocol is only used when the address is a hostname.
  #
  # If the address is:
  #
  #   - A hostname:
  #     It will be resolved
  #   - An IPv4 address:
  #     It will be qualified with a /32 CIDR notation
  #   - An IPv6 address:
  #     It will be qualified with a /128 CIDR notation
  #   - An IP address with a CIDR notation:
  #     It will be normalised
  #   - An IP address with a dotted-quad netmask:
  #     It will be converted to CIDR notation
  #   - Any address with a resulting prefix length of zero:
  #     It will return nil which is equivilent to not specifying an address
  #
  def host_to_ip(value, proto = nil)
    begin
      value = Puppet::Util::IPCidr.new(value)
    rescue
      family = case proto
               when :IPv4
                 Socket::AF_INET
               when :IPv6
                 Socket::AF_INET6
               when nil
                 raise ArgumentError, 'Proto must be specified for a hostname'
               else
                 raise ArgumentError, "Unsupported address family: #{proto}"
               end

      new_value = nil
      Resolv.each_address(value) do |addr|
        begin # rubocop:disable Style/RedundantBegin
          new_value = Puppet::Util::IPCidr.new(addr, family)
          break
        rescue # looking for the one that works # rubocop:disable Lint/SuppressedException
        end
      end

      raise "Failed to resolve hostname #{value}" if new_value.nil?
      value = new_value
    end

    return nil if value.prefixlen.zero?
    value.cidr
  end

  # Takes an address mask and protocol and converts the host portion to CIDR
  # notation.
  #
  # This takes into account you can negate a mask but follows all rules
  # defined in host_to_ip for the host/address part.
  #
  def host_to_mask(value, proto)
    match = value.match %r{(!)\s?(.*)$}
    return host_to_ip(value, proto) unless match

    cidr = host_to_ip(match[2], proto)
    return nil if cidr.nil?
    "#{match[1]} #{cidr}"
  end

  # Validates the argument is int or hex, and returns valid hex
  # conversion of the value or nil otherwise.
  def to_hex32(value)
    begin
      value = Integer(value)
      if value.between?(0, 0xffffffff)
        return '0x' + value.to_s(16)
      end
    rescue ArgumentError
      # pass
    end
    nil
  end

  def persist_iptables(proto)
    debug('[persist_iptables]')

    # Basic normalisation for older Facter
    os_key = Facter.value(:osfamily)
    os_key ||= case Facter.value(:operatingsystem)
               when 'RedHat', 'CentOS', 'Fedora', 'Scientific', 'SL', 'SLC', 'Ascendos', 'CloudLinux',
                    'PSBM', 'OracleLinux', 'OVS', 'OEL', 'Amazon', 'XenServer', 'VirtuozzoLinux', 'Rocky', 'AlmaLinux'
                 'RedHat'
               when 'Debian', 'Ubuntu'
                 'Debian'
               else
                 Facter.value(:operatingsystem)
               end

    # Older iptables-persistent doesn't provide save action.
    if os_key == 'Debian'
      # We need to call flush to clear Facter cache as it's possible the cached value will be nil due to the fact
      # that the iptables-persistent package was potentially installed after the initial Fact gathering.
      fact = Facter.fact(:iptables_persistent_version)
      fact.flush if fact.respond_to?(:flush)
      persist_ver = fact.value
      if persist_ver && Puppet::Util::Package.versioncmp(persist_ver, '0.5.0') < 0
        os_key = 'Debian_manual'
      end
    end

    # Fedora 15 and newer use systemd to persist iptable rules
    if os_key == 'RedHat' && Facter.value(:operatingsystem) == 'Fedora' && Facter.value(:operatingsystemrelease).to_i >= 15
      os_key = 'Fedora'
    end

    # RHEL 7 and newer also use systemd to persist iptable rules
    if os_key == 'RedHat' && ['RedHat', 'CentOS', 'Scientific', 'SL', 'SLC', 'Ascendos', 'CloudLinux', 'PSBM', 'OracleLinux', 'OVS', 'OEL', 'XenServer', 'VirtuozzoLinux', 'Rocky', 'AlmaLinux']
       .include?(Facter.value(:operatingsystem)) && Facter.value(:operatingsystemrelease).to_i >= 7
      os_key = 'Fedora'
    end

    if os_key == 'RedHat' && Facter.value(:operatingsystem) == 'Amazon'
      os_key = 'Amazon'
    end

    cmd = case os_key.to_sym
          when :RedHat
            case proto.to_sym
            when :IPv4
              ['/sbin/service', 'iptables', 'save']
            when :IPv6
              ['/sbin/service', 'ip6tables', 'save']
            end
          when :Fedora
            case proto.to_sym
            when :IPv4
              ['/usr/libexec/iptables/iptables.init', 'save']
            when :IPv6
              ['/usr/libexec/iptables/ip6tables.init', 'save']
            end
          when :Debian
            case proto.to_sym
            when :IPv4, :IPv6
              if persist_ver && Puppet::Util::Package.versioncmp(persist_ver, '1.0') > 0
                ['/usr/sbin/service', 'netfilter-persistent', 'save']
              else
                ['/usr/sbin/service', 'iptables-persistent', 'save']
              end
            end
          when :Debian_manual
            case proto.to_sym
            when :IPv4
              ['/bin/sh', '-c', '/sbin/iptables-save > /etc/iptables/rules']
            end
          when :Archlinux
            case proto.to_sym
            when :IPv4
              ['/bin/sh', '-c', '/usr/sbin/iptables-save > /etc/iptables/iptables.rules']
            when :IPv6
              ['/bin/sh', '-c', '/usr/sbin/ip6tables-save > /etc/iptables/ip6tables.rules']
            end
          when :Amazon
            case proto.to_sym
            when :IPv4
              ['/bin/sh', '-c', '/usr/sbin/iptables-save > /etc/sysconfig/iptables.rules']
            when :IPv6
              ['/bin/sh', '-c', '/usr/sbin/ip6tables-save > /etc/sysconfig/ip6tables.rules']
            end
          when :Suse
            case proto.to_sym
            when :IPv4
              ['/bin/sh', '-c', '/usr/sbin/iptables-save > /etc/sysconfig/iptables']
            end
          end

    # Catch unsupported OSs from the case statement above.
    if cmd.nil?
      debug('firewall: Rule persistence is not supported for this type/OS')
      return
    end

    begin
      execute(cmd)
    rescue Puppet::ExecutionFailure => detail
      warning("Unable to persist firewall rules: #{detail}")
    end
  end
end
