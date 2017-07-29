require 'resolv'
require 'base64'
require 'unix_crypt'

class QueryError < StandardError; end

class NilClass

  # these defs allow for the case where something wasn't found to
  # give a nil response rather than crashing--for example:
  #  mx = "example.com" # => nil (because example.com has no MX record)
  #  ip = mx.dig_a # => nil, without crashing
  # otherwise, it would be necessary to write:
  #  mx = "example.com" # => nil (because example.com has no MX record)
  #  ip = if mx then ip = mx.dig_a else ip = nil end
  def dig_a; nil; end
  def dig_aaaa; nil; end
  def dig_mx; nil; end
  def dig_dk; nil; end
  def dig_ptr; nil; end
  def mta_live?(port); nil; end
  def validate_plain; return "", false; end

end

class String

  # returns list of IPV4 addresses, or nil
  # (there should only be one IPV4 address)
  def dig_a
    Resolv::DNS.open do |dns|
      txts = dns.getresources(self,Resolv::DNS::Resource::IN::A).collect { |r| r.address.to_s }
      if txts.empty? then nil else txts[0] end
    end
  end

  # returns list of IPV6 addresses, or nil
  # (there should only be one IPV6 address)
  def dig_aaaa
    Resolv::DNS.open do |dns|
      txts = dns.getresources(self,Resolv::DNS::Resource::IN::AAAA).collect { |r| r.address.to_s.downcase }
      if txts.empty? then nil else txts[0] end
    end
  end

  # returns list of MX names, or nil
  # (there may be multiple MX names for a domain)
  # WARNING: use the #dig_mxs to get the preferences also
  def dig_mx
    Resolv::DNS.open do |dns|
      txts = dns.getresources(self,Resolv::DNS::Resource::IN::MX).collect { |r| r.exchange.to_s }
      if txts.empty? then nil else txts end
    end
  end

  # returns a hash of { <preference> => [ <mx,ip>, ... ] }
  # preferences sorted in numerical order from low-->high
  # (IOW, highest preference to lowest preference)
  # if there is no mx, returns {}
  # ex: {10=>[["aspmx.l.google.com", "173.194.78.26"]],
  #      20=>[["alt1.aspmx.l.google.com", "173.194.219.27"]],
  #      30=>[["alt2.aspmx.l.google.com", "74.125.192.27"], ["alt3.aspmx.l.google.com", "74.125.141.27"]],
  #      40=>[["alt4.aspmx.l.google.com", "64.233.190.26"]]}
  def dig_mxs
    mxs = {}
    Resolv::DNS.open do |dns|
      res = dns.getresources(self,Resolv::DNS::Resource::IN::MX)
      if res.size>0
        res = res.sort {|a,b| a.preference<=>b.preference }
        res.each do |mx|
          mxs[mx.preference] ||= []
          domain = mx.exchange.to_s
          ip = domain.dig_a
          mxs[mx.preference] << [domain,ip]
        end
      end
    end
    return mxs
  end

  # returns a publibdomainkey, or nil
  # (there should only be one DKIM public key)
  def dig_dk
    Resolv::DNS.open do |dns|
      txts = dns.getresources(self,Resolv::DNS::Resource::IN::TXT).collect { |r| r.strings }
      if txts.empty? then nil else txts[0][0] end
    end
  end

  # returns a reverse DNS hostname or nil
  def dig_ptr
    begin
      Resolv.new.getname(self.downcase)
    rescue Resolv::ResolvError
      nil
    end
  end

  # returns true if the IP is blacklisted; otherwise false
  # examples:
  # barracuda = 'b.barracudacentral.org'.blacklisted?(ip)
  # spamhaus = 'zen.spamhaus.org'.blacklisted?(ip)
  def blacklisted?(dx)
    domain = dx.split('.').reverse.join('.')+"."+self
    a = []
    Resolv::DNS.open do |dns|
      begin
        a = dns.getresources(domain, Resolv::DNS::Resource::IN::A)
      rescue Resolv::NXDomainError
        a=[]
      end
    end
    if a.size>0 then true else false end
  end

  # returns a UTF-8 encoded string -- be carefule using this with email:
  # email has to be received and transported with NO changes, except the
  # addition of extra headers at the beginning (before any DKIM headers)
  def utf8
    self.encode('UTF-8', 'binary', :invalid => :replace, :undef => :replace, :replace => '?')
  end

  # opens a socket to the IP/port to see if there is an SMTP server
  # there - returns "250 ..." if the server is there, or 
  # times out in 5 seconds to prevent hanging the process
  def mta_live?(port)
    tcp_socket = nil
    welcome = nil
    begin
      Timeout.timeout(60) do
        begin
          tcp_socket = TCPSocket.open(self,port)
        rescue Errno::ECONNREFUSED => e
          return "421 Service not available (port closed)"
        end
        begin
          welcome = tcp_socket.gets
          return welcome if welcome[1]!='2'
          tcp_socket.write("QUIT\r\n")
          line = tcp_socket.gets
          return line if line[1]!='2'
        ensure
          tcp_socket.close if tcp_socket
        end
      end
      return "250 #{welcome.chomp[4..-1]}"
    rescue SocketError => e
      return "421 Service not available (#{e.to_s})"
    rescue Timeout::Error => e
      return "421 Service not available (#{e.to_s})"
    end
  end

  # this validates a password with the base64 plaintext in an AUTH command
  # encoded -> AGNvY29AY3phcm1haWwuY29tAG15LXBhc3N3b3Jk => ["coco@example.com", "my-password"]
  # call UnixCrypt::SHA256.build("my-password")
  # "my-password" --> "$5$BsHk6IIvndgdBmo9$iuO6WMaXzgzpGmGreV4uiH72VRGG1USNK/e5tL7P9jC"
  # "AGNvY29AY3phcm1haWwuY29tAG15LXBhc3N3b3Jk".validate_plain { "$5$BsHk6IIvndgdBmo9$iuO6WMaXzgzpGmGreV4uiH72VRGG1USNK/e5tL7P9jC" } => "coco@example.com", true
  def validate_plain
    # decode and split up the username and password)
    username, password = Base64::decode64(self).split("\x00")[1..-1]
    return "", false if username.nil? || password.nil?
    passwd_hash = yield(username) # get the hash
    return username, false if passwd_hash.nil?
    return username, UnixCrypt.valid?(password, passwd_hash)
  end

end
