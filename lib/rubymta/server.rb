require 'logger'
require 'socket'
require 'ostruct'
require 'optparse'
require 'openssl'
require 'sequel'
require 'sqlite3'
require 'etc'
require 'pretty_inspect'

class Terminate < Exception; end
class Quit < Exception; end

# Set up the $app hash for systemwide parameters
$app = {}
$app[:path] = Dir::pwd
$app[:mode] = ENV['MODE']

require './config'
include Config
$app[:uinfo] = Etc::getpwnam(UserName) if UserName
$app[:ginfo] = Etc::getgrnam(GroupName) if GroupName

require_relative 'receiver'

# get setup and open the log
LOG = Logger::new(LogPathAndFile, LogFileLife)
LOG.level = LogLevel
LOG.formatter = proc do |severity, datetime, progname, msg|
  pname = if progname then '('+progname+') ' else nil end
  "#{datetime.strftime("%Y-%m-%d %H:%M:%S")} [#{severity}] #{pname}#{msg}\n"
end

# Make sure the MODE environmental variable is valid
if ['dev','live'].index(ENV['MODE']).nil?
  msg = "Environmental variable MODE not set properly--must be dev or live"
  LOG.fatal(msg)
  puts msg
  exit(1)
end

# set the owner of the LOG file to UserName and
# GroupName--this is because otherwise, a new log file
# will be created as root:root, and run_queue won't be
# able to open it--this only is needed if 'server' is
# running as root; same for the sqlite database
if !UserName.nil?
  File::chown($app[:uinfo].uid, $app[:ginfo].gid, LogPathAndFile)
  File::chown($app[:uinfo].uid, $app[:ginfo].gid, S3DBPath)
end

# This changed as of Sequel v.4.40.0
# This is false by default, but was supposed to be
# true by default so we have to forcefully set it
Sequel.split_symbols = true

# Open the sqlite3 database for rubymta use
S3DB = Sequel.connect("sqlite://#{S3DBPath}")
LOG.debug("Database '#{S3DBPath}' opened")

# Create the tables we need if they don't already exist

# The contacts table is just used to count the number of 'hits' for
# a particular IP address in order to choose between sending an
# "Access TEMPORARILY denied" or just slam the port shut
S3DB::create_table?(:contacts) do
  primary_key(:id)
  string(:remote_ip)
  integer(:hits)
  integer(:locks)
  integer(:violations)
  datetime(:expires_at)
  datetime(:created_at)
  datetime(:updated_at)
  index(:remote_ip)
end

# The queue table is used to track the emails server/receiver receive. The
# queue runner will read this queue and attempt to deliver the emails.
S3DB::create_table?(:parcels) do
  primary_key(:id)
  integer(:contact_id)
  string(:mail_id)
  string(:from_url)
  string(:to_url)
  string(:delivery) # 'local' or 'remote'
  datetime(:delivery_at)
  text(:delivery_msg)
  datetime(:retry_at)
  datetime(:created_at)
  datetime(:updated_at)
  index([:mail_id,:from_url])
  index([:mail_id,:to_url])
end

# load the DKIM private key for this domain, if any
$app[:dkim] = nil
File::open(DKIMPrivateKeyFile, "r") { |f| $app[:dkim] = f.read } if DKIMPrivateKeyFile

# MAIN server class -- starts at Server#start
class Server

  include Socket::Constants

#  def restart
#    # handle a HUP request here
#  end

  # this is the code executed after the process has been
  # forked and root privileges have been dropped
  def process_call(connection, local_port, remote_port, remote_ip, remote_hostname, remote_service)
    begin
      Signal.trap("INT") { } # ignore ^C in the child process
      LOG.info("%06d"%Process::pid) {"Connection accepted on port #{local_port} from port #{remote_port} at #{remote_ip} (#{remote_hostname})"}

      # a new object is created here to provide separation between server and receiver
      # this call receives the email and does basic validation
      Receiver::new(connection).receive(local_port, Socket::gethostname, remote_port, remote_hostname, remote_ip)
    rescue Quit
      # nothing to do here
    ensure
      # close the database (the child's copy)
      S3DB.disconnect if S3DB
      nil # don't return the Receiver object
    end
  end

  # this method drops the process's root privileges for security reasons
  def drop_root_privileges
    if Process::Sys.getuid==0
      Dir.chdir($app[:path]) if not $app[:path].nil?
      Process::GID.change_privilege($app[:ginfo].gid)
      Process::UID.change_privilege($app[:uinfo].uid)
    end
  end

  # both the AF_INET and AF_INET6 families use this DRY method
  def bind_socket(family,port,ip)
    socket = Socket.new(family, SOCK_STREAM, 0)
    sockaddr = Socket.sockaddr_in(port.to_i,ip)
    socket.setsockopt(:SOCKET, :REUSEADDR, true)
    socket.bind(sockaddr)
    socket.listen(0)
    return socket
  end

  # the listening thread is established in this method depending on the ListenPort
  # argument passed to it -- it can be '<ipv6>/<port>', '<ipv4>:<port>', or just '<port>'
  def listening_thread(local_port)
    LOG.info("%06d"%Process::pid) {"listening on port #{local_port}..."}
    
    # check the parameter to see if it's valid
    m = /^(([0-9a-fA-F]{0,4}:{0,1}){1,8})\/([0-9]{1,5})|(([0-9]{1,3}\.{0,1}){4}):([0-9]{1,5})|([0-9]{1,5})$/.match(local_port)
    #<MatchData "2001:4800:7817:104:be76:4eff:fe05:3b18/2000" 1:"2001:4800:7817:104:be76:4eff:fe05:3b18" 2:"3b18" 3:"2000" 4:nil 5:nil 6:nil 7:nil>
    #<MatchData "23.253.107.107:2000" 1:nil 2:nil 3:nil 4:"23.253.107.107" 5:"107" 6:"2000" 7:nil>
    #<MatchData "2000" 1:nil 2:nil 3:nil 4:nil 5:nil 6:nil 7:"2000">
    case
      when !m[1].nil? # its AF_INET6
        socket = bind_socket(AF_INET6,m[3],m[1])
      when !m[4].nil? # its AF_INET
        socket = bind_socket(AF_INET,m[6],m[4])
      when !m[7].nil?
        socket = bind_socket(AF_INET6,m[7],"0:0:0:0:0:0:0:0")
      else
        raise ArgumentError.new(local_port)
    end
    ssl_server = OpenSSL::SSL::SSLServer.new(socket, $ctx);

    # main listening loop starts in non-encrypted mode
    ssl_server.start_immediately = false
    loop do
      # we can't use threads because if we drop root privileges on any thread,
      # they will be dropped for all threads in the process--so we have to fork
      # a process here in order that the reception be able to drop root privileges
      # and run at a user level--this is a security precaution
      connection = ssl_server.accept
      Process::fork do
        begin
          drop_root_privileges if !UserName.nil?
          begin
            remote_hostname, remote_service = connection.io.remote_address.getnameinfo
          rescue SocketError => e
            LOG.info("%06d"%Process::pid) { e.to_s }
            remote_hostname, remote_service = "(none)", nil
          end
          remote_ip, remote_port = connection.io.remote_address.ip_unpack
          process_call(connection, local_port, remote_port.to_s, remote_ip, remote_hostname, remote_service)
          LOG.info("%06d"%Process::pid) {"Connection closed on port #{local_port} by #{ServerName}"}
        rescue Errno::ENOTCONN => e
          LOG.info("%06d"%Process::pid) {"Remote Port scan on port #{local_port}"}
        ensure
          # here we close the child's copy of the connection --
          # since the parent already closed it's copy, this
          # one will send a FIN to the client, so the client
          # can terminate gracefully
          connection.close
          # and finally, close the child's link to the log
          LOG.close
        end
      end
      # here we close the parent's copy of the connection --
      # the child (created by the Process::fork above) has another copy --
      # if this one is not closed, when the child closes it's copy,
      # the child's copy won't send a FIN to the client -- the FIN
      # is only sent when the last process holding a copy to the
      # socket closes it's copy
      connection.close
    end
  end

  # this method parses the command line options
  def process_options
    options = OpenStruct.new
    options.log = Logger::INFO
    options.daemonize = false
    begin
      OptionParser.new do |opts|
        opts.on("--debug",  "Log all messages")     { |v| options.log = Logger::DEBUG }
        opts.on("--info",   "Log all messages")     { |v| options.log = Logger::INFO }
        opts.on("--warn",   "Log all messages")     { |v| options.log = Logger::WARN }
        opts.on("--error",  "Log all messages")     { |v| options.log = Logger::ERROR }
        opts.on("--fatal",  "Log all messages")     { |v| options.log = Logger::FATAL }
        opts.on("--daemonize", "Run as system daemon") { |v| options.daemonize = true }
      end.parse!
    rescue OptionParser::InvalidOption => e
      LOG.warn("%06d"%Process::pid) {"#{e.inspect}"}
    end
    options
  end # process_options

  def start
    # generate the first log messages
    LOG.info("%06d"%Process::pid) {"Starting RubyMTA at #{Time.now.strftime("%Y-%m-%d %H:%M:%S %Z")}, pid=#{Process::pid}"}
    LOG.info("%06d"%Process::pid) {"Options specified: #{ARGV.join(", ")}"} if ARGV.size>0

    # get the options from the command line
    @options = process_options
    LOG.level = @options.log

    # get the certificates, if any; they're needed for STARTTLS
    # we do this before daemonizing because the working folder might change
    $prv = if PrivateKey then OpenSSL::PKey::RSA.new File.read(PrivateKey) else nil end
    $crt = if Certificate then OpenSSL::X509::Certificate.new File.read(Certificate) else nil end

    # establish an SSL context for use in `listening_thread`
    $ctx = OpenSSL::SSL::SSLContext.new
    $ctx.key = $prv
    $ctx.cert = $crt

    # daemonize it if the option was set--it doesn't have to be root to daemonize it
    Process::daemon if @options.daemonize

    # get the process ID and the user id AFTER demonizing, if that was requested
    pid = Process::pid
    uid = Process::Sys.getuid
    gid = Process::Sys.getgid
    
    LOG.info("%06d"%Process::pid) {"Daemonized at #{Time.now.strftime("%Y-%m-%d %H:%M:%S %Z")}, pid=#{pid}, uid=#{uid}, gid=#{gid}"} #if @options.daemonize

    # store the pid of the server session
    begin
      LOG.info("%06d"%Process::pid) {"RubyMTA running as PID=>#{pid}, UID=>#{uid}, GID=>#{gid}"}
      File::open("#{PidPath}/rubymta.pid","w") { |f| f.write(pid.to_s) }
    rescue Errno::EACCES => e
      LOG.warn("%06d"%Process::pid) {"The pid couldn't be written. To save the pid, create a directory '#{PidPath}' with r/w permissions for this user."}
      LOG.warn("%06d"%Process::pid) {"Proceeding without writing the pid."}
    end

    # if rubymta was started as root, make sure UserName and
    # GroupName have values because we have to drop root privileges
    # after we fork a process for the receiver
    if uid==0 # it's root
      if UserName.nil? || GroupName.nil?
        LOG.error("%06d"%Process::pid) {"rubymta can't be started as root unless UserName and GroupName are set."}
        exit(1)
      end
    end

    # this is the main loop which runs until admin enters ^C
    Signal.trap("INT") { raise Terminate.new }
    Signal.trap("HUP") { restart if defined?(restart) }
    Signal.trap("CHLD") do
      begin
      Process.wait(-1, Process::WNOHANG)
      rescue Errno::ECHILD => e
        # ignore the error
      end
    end
    threads = []
    # start the server on multiple ports (the usual case)
    begin
      ListeningPorts.each do |port|
        threads << Thread.start(port) do |port|
          listening_thread(port)
        end
      end
      # the joins are done ONLY after all threads are started
      threads.each { |thread| thread.join }
    rescue Terminate
      LOG.info("%06d"%Process::pid) {"#{ServerName} terminated by admin ^C"}
    end

  ensure

    # attempt to remove the pid file
    begin
      File.delete("#{PidPath}/rubymta.pid")
    rescue Errno::ENOENT => e
      LOG.warn("%06d"%Process::pid) {"No such file: #{e.inspect}"}
    rescue Errno::EACCES, Errno::EPERM
      LOG.warn("%06d"%Process::pid) {"Permission denied: #{e.inspect}"}
    end

    # close the log
    LOG.close if LOG
  end

end
