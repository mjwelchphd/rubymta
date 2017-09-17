require 'timeout'
require 'pretty_inspect'
require 'openssl'
require 'logger'
require 'pdkim'

LocalLMTPPort = 24

def manually_run_queue_runner
  exit unless File::open(LockFilePath,"w").flock(File::LOCK_NB | File::LOCK_EX)
  QueueRunner.new.run_queue
end

class QueueRunner

  include Socket::Constants
  include PDKIM

  RetryInterval = 5*60;

  def initialize
  end

  # send text to the client
  def send_text(text,echo=:command)
    puts "<-  #{text.inspect}" if DisplayQueueRunnerDialog
    if text.class==Array
      text.each do |line|
        @connection.write(line+CRLF)
        LOG.info(@mail_id) {"<-  %s"%text} if LogQueueRunnerConversation
      end
    else
      @connection.write(text+CRLF)
      LOG.info(@mail_id) {"<-  %s"%text} if LogQueueRunnerConversation
    end
  end

  # receive text from the client
  def recv_text
    begin
    lines = []
    Timeout.timeout(QueueRunnerTimeout) do
      tmp = @connection.gets
      lines << (line = if tmp.nil? then "" else tmp.chomp end)
      LOG.info((@mail_id)) {" -> %s"%line} if LogQueueRunnerConversation
      while line[3]=='-'
        tmp = @connection.gets
        lines << (line = if tmp.nil? then "" else tmp.chomp end)
        LOG.info((@mail_id)) {" -> %s"%line} if LogQueueRunnerConversation
      end
      ok = lines.last[0]
      lines.each {|line| puts " -> #{line.inspect}"} if DisplayQueueRunnerDialog
      return ok, lines
    end
    rescue Timeout::Error => e
      return '5', "500 5.0.0 No data received after #{QueueRunnerTimeout} seconds (Time Out)"
    end
  end

  def run_queue
    @mail_id = nil
    LOG.info(Time.now.strftime("%Y-%m-%d %H:%M:%S")) {"Queue runner started"}
    n=3 # used for a sanity check
    while true
      # sqlite3 has a bug: "<=" doesn't work with time, ex. "retry_at<='#{Time.now}'"
      # we have to add 1 second and use "<"; ex. "retry_at<'#{Time.now+1}'"
      parcels = S3DB[:parcels].where(Sequel.lit("(delivery<>'none') and (delivery_at is null) and ((retry_at is null) or (retry_at<'#{Time.now + 1}'))")).all
      return if parcels.empty?

      # aggregate the emails by destination domain
      deliver = {}
      parcels.each do |parcel|
        if parcel[:delivery]!='none' && !parcel[:delivery_at]
          mail_id = deliver[parcel[:mail_id]] ||= {}
          domain = mail_id[parcel[:to_url].split('@')[1]] ||= {}
          domain[parcel[:to_url]] = parcel
        end
      end

      # send mail to each domain--success or failure will be
      # handled in the respective mail routine
      mail = {}
      deliver.each do |mail_id, domains|
        (mail = ItemOfMail::retrieve_mail_from_queue_folder(mail_id)) if mail[:mail_id]!=mail_id
        domains.each do |domain, parcels|

#=== compare before and after ======================================
#puts "--> *2* domain=>#{domain.inspect}"
#parcels.values.each { |parcel| puts "--> *3* #{parcel.inspect}" }
#===================================================================

          @mail_id = mail[:mail_id]
          deliver_and_save_status(mail, domain, parcels.values)
          @mail_id = nil

#===================================================================
#parcels.values.each { |parcel| puts "--> *4* #{parcel.inspect}" }
#===================================================================
        end
      end
      if (n-=1)<0
        LOG.info(Time.now.strftime("%Y-%m-%d %H:%M:%S")) {"In QueueRunner, the loop repeated 3 times. Is somthing wrong?"}
        return nil
      end
    end
  ensure
    LOG.info(Time.now.strftime("%Y-%m-%d %H:%M:%S")) {"Queue runner finished"}
  end

  def deliver_and_save_status(mail,domain,parcels)
    # the methods lmtp_delivery and smtp_delivery will change
    # the status upon successful delivery

    # get the certificates, if any; they're needed for STARTTLS
    $prv = if PrivateKey then OpenSSL::PKey::RSA.new File.read(PrivateKey) else nil end
    $crt = if Certificate then OpenSSL::X509::Certificate.new File.read(Certificate) else nil end

    # establish an SSL context
    $ctx = OpenSSL::SSL::SSLContext.new
    $ctx.key = $prv
    $ctx.cert = $crt

    begin
      case parcels.first[:delivery]
#==================================================
      when "local"
        begin
          ssl_socket = TCPSocket.open('localhost',LocalLMTPPort)
          @connection = OpenSSL::SSL::SSLSocket.new(ssl_socket, $ctx);
          lmtp_delivery('localhost',LocalLMTPPort,mail,domain,parcels)
          mail.update_parcels(parcels)
        rescue Errno::ECONNREFUSED => e
          LOG.info(@mail_id) {"Connection to localhost failed: #{e}"}
          mark_parcels(parcels, "441 4.0.0 Connection to localhost failed")
        end
#==================================================
      when "remote"
        # this looks through the list of MXs and finds the
        # first one that can communicate
        mail[:rcptto].each do |rcptto|
          if rcptto[:domain]==domain
            rcptto[:mxs].each do |preference,pairs|
              pairs.each do |mx,ip|
                begin
                  # open the connection
                  ssl_socket = TCPSocket.open(mx,RemoteSMTPPort)
                  @connection = OpenSSL::SSL::SSLSocket.new(ssl_socket, $ctx);
                  smtp_delivery(mx, RemoteSMTPPort, mail, domain, parcels)
                  mail.update_parcels(parcels)
                  return
                rescue Errno::ETIMEDOUT => e
                  LOG.info(@mail_id) {"Service for #{mx} not available (timeout)"}
                rescue Errno::ECONNREFUSED => e
                  LOG.info(@mail_id) {"Service for #{mx} not available (refused)"}
                end
              end
              # delivery was remote, and no MX was connectable
              mark_parcels(parcels, "441 4.0.0 No MX for <#{domain}> has an operational mail server")
            end
          end
        end
#==================================================
      when 'none'
        # just ignore the email--it will not be delivered
      else
        # we didn't program a delivery option, so it got here
        mark_parcels(parcels, "500 5.0.0 Delivery option '#{parcel[:delivery]} not supported")
      end
    rescue => e
      LOG.info(@mail_id) {"Rescue #{e.inspect}"}
      e.backtrace.each { |line| LOG.fatal(mail[:mail_id]) { line } }
      mark_parcels(parcels, "441 4.0.0 Rescue #{e.inspect}")
    end
  ensure
    if @connection
      send_text("QUIT")
      ok, lines = recv_text # ignore returns
      @connection.close
    end
  end

  def mark_parcels(parcels, responses)
    response = if responses.kind_of?(Array) then responses.last else responses end
    parcels.each do |parcel|
      parcel[:delivery_at] = if response[0]!='4' then Time.now else nil end
      parcel[:delivery_msg] = response
      parcel[:retry_at] = if response[0]=='4' then Time.now + RetryInterval else nil end
    end
    nil
  end

# SAMPLE SMTP TRANSFER
# <-  220 2.0.0 mail.xyz.com ESMTP Xyz, LLC 0.01 THU, 24 NOV 2016 20:22:39 +0000
#  -> EHLO foo.com
# <-  250-2.0.0 mail.xyz.com Hello foo.com at 213.33.76.136
# <-  250-AUTH PLAIN
# <-  250-STARTTLS
# <-  250 HELP
#---- This part is only if there is a logon/password supplied ----
#  -> STARTTLS
# <-  220 2.0.0 TLS go ahead
# === TLS started with cipher TLSv1.2:DHE-RSA-AES256-GCM-SHA384:256
# === TLS no local certificate set
# === TLS peer DN="/C=US/ST=CA/L=Los Angeles/O=Xyz, LLC/CN=xyz.com/emailAddress=admin@xyz.com"
#  ~> EHLO foo.com
# <~  250-2.0.0 mail.xyz.com Hello foo.com at 213.33.76.136
# <~  250-AUTH PLAIN
# <~  250 HELP
#  ~> MAIL FROM:John Q. Public <JQP@foo.com>
# <~  250 2.0.0 OK
#  ~> RCPT TO:<Jones@xyz.com>
# <~  250 2.0.0 OK
#  ~> DATA
# <~  354 Enter message, ending with "." on a line by itself
#  ~> Date: Thu, 24 Nov 2016 12:22:39 -0800
#  ~> To: Jones@xyz.com
#  ~> From: John Q. Public <JQP@bar.com>
#  ~> Subject: test Thu, 24 Nov 2016 12:22:39 -0800
#  ~> 
#  ~> Bill:
#  ~>  The next meeting of the board of directors will be
#  ~>  on Tuesday.
#  ~>                          John.
#  ~> .
# <~  250 OK
#  ~> QUIT
# <~  221 2.0.0 OK mail.xyz.com closing connection

  def smtp_delivery(host, port, mail, domain, parcels, username=nil, password=nil)
    LOG.info(@mail_id) {"Beginning delivery of #{mail[:id]} to remote server at #{host}"}

    # receive the server's welcome message
    ok, lines = recv_text
    return mark_parcels(parcels, lines) if ok!='2'

    # send the EHLO
    send_text("EHLO #{mail[:local_hostname]}")
    ok, lines = recv_text
    return mark_parcels(parcels, lines) if ok!='2'

    # check for STARTTLS supported by server
    if !lines.select{ |line| line.index("STARTTLS") }.empty?
      send_text("STARTTLS")
      ok, lines = recv_text
      return mark_parcels(parcels, lines) if ok!='2'

      # enable TLS
      @connection.connect
      LOG.info(@mail_id) {"<-> (handshake)"}

      send_text("EHLO #{mail[:local_hostname]}")
      ok, lines = recv_text
      return mark_parcels(parcels, lines) if ok!='2'
    end

    # AUTH PLAIN -- log onto server
    if username
      user_pass = Base64::encode64("\0#{username}\0#{password}").chomp
      send_text("AUTH PLAIN #{user_pass}")
      ok, lines = recv_text
      return mark_parcels(parcels, lines) if ok!='2'
    end

    # MAIL FROM
    send_text("MAIL FROM:<#{mail[:mailfrom][:url]}>")
    ok, lines = recv_text
    return mark_parcels(parcels, lines) if ok!='2'

    # RCPT TO
    parcels.each do |parcel|
      send_text("RCPT TO:<#{parcel[:to_url]}>")
      ok, lines = recv_text
      # if there's a problem, we mark this parcel (recipient), but keep processing others
      mark_parcels(parcels, lines) if ok!='2'
    end

    # DATA -- send the email
    send_text("DATA")
    ok, lines = recv_text
    return mark_parcels(parcels, lines) if ok!='3'

    LOG.info(@mail_id) {"<-  (data)"} if LogQueueRunnerConversation
    mail[:data][:text].each do |line|
      send_text(line, :data)
    end

    # send the end of the message prompt
    send_text(".", :data)

    # get one final message for all parcels (recipients)
    ok, lines = recv_text
    return mark_parcels(parcels, lines)
  end

# SAMPLE LMTP TRANSFER
# <-  220 foo.edu LMTP server ready
#  -> LHLO foo.edu
# <-  250-foo.edu
# <-  250-PIPELINING
# <-  250 SIZE
#  -> MAIL FROM:<chris@bar.com>
# <-  250 OK
#  -> RCPT TO:<pat@foo.edu>
# <-  250 OK
#  -> RCPT TO:<jones@foo.edu>
# <-  550 No such user here
#  -> RCPT TO:<green@foo.edu>
# <-  250 OK
#  -> DATA
# <~  354 Enter message, ending with "." on a line by itself
#  ~> Date: Thu, 24 Nov 2016 12:22:39 -0800
#  ~> To: Jones@xyz.com
#  ~> From: John Q. Public <JQP@bar.com>
#  ~> Subject: test Thu, 24 Nov 2016 12:22:39 -0800
#  ~> 
#  ~> Bill:
#  ~>  The next meeting of the board of directors will be
#  ~>  on Tuesday.
#  ~>                          John.
#  ~> .
# <~  250 OK
# <-  452 <green@foo.edu> is temporarily over quota (reply for <green@foo.edu>)
#  -> QUIT
# <-  221 foo.edu closing connection
#
# Note: there was no reply for <jones@foo.edu> because it failed in the RCPT TO command

  # domain (for local) is 'localhost', and parcels is an array of hashes (recipients) --
  # the single key is the domain to which to send the email -- since all recipients
  # are in the same domain, we can send only one email with all recipients named in
  # RCPT TOs -- this delivery is for Dovecot, so we believe the domain is 'ServerName'
  def lmtp_delivery(host, port, mail, domain, parcels)
    LOG.info(@mail_id) {"Beginning delivery of #{mail[:mail_id]} to Dovecot at #{ServerName}"}

    # receive the server's welcome message
    ok, lines = recv_text
    return mark_parcels(parcels, lines) if ok!='2'

    # send the LHLO
    send_text("LHLO #{mail[:local_hostname]}")
    ok, lines = recv_text
    return mark_parcels(parcels, lines) if ok!='2'

    # MAIL FROM
    send_text("MAIL FROM:<#{mail[:mailfrom][:url]}>")
    ok, lines = recv_text
    return mark_parcels(parcels, lines) if ok!='2'

    # RCPT TO
    parcels.each do |parcel|
      send_text("RCPT TO:<#{parcel[:to_url]}>")
      ok, lines = recv_text
      # if there's a problem, we mark this pacel (recipient), but keep processing others
      mark_parcels([parcel], lines) if ok!='2'
    end

    # DATA -- send the email
    send_text("DATA")
    ok, lines = recv_text
    return mark_parcels(parcels, lines) if ok!='3'

    LOG.info(@mail_id) {"<-  (data)"} if LogQueueRunnerConversation
    mail[:data][:text].each do |line|
      send_text(line, :data)
    end

    # send the end of the message prompt
    send_text(".", :data)

    # get one final message for each recipient
    parcels.each do |parcel|
      # get the response from DoveCot
      ok, lines = recv_text
      mark_parcels([parcel], lines)
    end
  end

  # to send an alert email to a registered user --
  # this just delivers the message to dovecot with no processing --
  # the caller is responsible to provide valid arguments
  def send_local_email(from, to, subject, text)
    @connection = nil

    # open connection
    ssl_socket = TCPSocket.open('localhost',LocalLMTPPort)
    @connection = OpenSSL::SSL::SSLSocket.new(ssl_socket);

    # receive the server's welcome message
    ok, lines = recv_text
    return ok, lines if ok!='2'

    # send the LHLO
    send_text("LHLO admin")
    ok, lines = recv_text
    return ok, lines if ok!='2'

    # MAIL FROM
    send_text("MAIL FROM:<#{from}>")
    ok, lines = recv_text
    return ok, lines if ok!='2'

    # RCPT TO
    send_text("RCPT TO:<#{to}>")
    ok, lines = recv_text
    return ok, lines if ok!='2'

    # DATA -- send the email
    send_text("DATA")
    ok, lines = recv_text
    return ok, lines if ok!='3'
    lines = <<ALERT
To: <#{to}>
From: <#{from}>
Subject: #{subject}
Date: #{Time.now.strftime("%a, %d %b %Y %H:%M:%S %z")}

#{text}
ALERT
    lines.split("\n").each do |line|
      send_text(line, :data)
    end

    # send the end of the message prompt
    send_text(".", :data)

    # get the response from DoveCot
    return recv_text

  ensure
    @connection.close if @connection
  end

end

def send_local_alert(from, to, subject, text)
  QueueRunner::new.send_local_email(from, to, subject, text)
end
