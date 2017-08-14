require 'timeout'
require 'pdkim'
require_relative "item_of_mail"
require_relative "contact"
require_relative "extended_classes"
require_relative "queue_runner"
require 'pretty_inspect'

CRLF = "\r\n"

class Receiver
  # PDKIM Verify Codes
  PdkimReturnCodes = ["0-Verify not completed", "1-Verify invalid", "2-Verify failed", "3-Verify passed"]

  include Config
  include PDKIM
  include Version

  Patterns = [
    [0, "[ /t]*QUIT[ /t]*", :quit],
    [1, "[ /t]*AUTH[ /t]*(.+)", :auth_base],
    [1, "[ /t]*EHLO(.*)", :ehlo_base],
    [1, "[ /t]*EXPN[ /t]*(.*)", :expn_base],
    [1, "[ /t]*HELO[ /t]+(.*)", :ehlo_base],
    [1, "[ /t]*HELP[ /t]*(.*)", :help_base],
    [1, "[ /t]*NOOP[ /t]*(.*)", :noop_base],
    [1, "[ /t]*RSET[ /t]*(.*)", :rset_base],
    [1, "[ /t]*TIMEOUT[ /t]*", :timeout],
    [1, "[ /t]*VFRY[ /t]*(.*)", :vfry_base],
    [2, "[ /t]*STARTTLS[ /t]*", :starttls],
    [2, "[ /t]*MAIL FROM[ /t]*:[ \t]*(.+)", :mail_from_base],
    [3, "[ /t]*RCPT TO[ /t]*:[ \t]*(.+)", :rcpt_to_base],
    [4, "[ /t]*DATA[ /t]*", :data_base]
  ]

  def initialize(connection)
    @connection = connection
  end

  Unexpectedly = "; probably caused by the client closing the connection unexpectedly"

#-------------------------------------------------------#
#--- Send text to the client ---------------------------#
#-------------------------------------------------------#
  def send_text(text,echo=true)
    puts "<-  #{text.inspect}" if DisplayReceiverDialog
    begin
      case
      when text.nil?
        # do nothing
      when text.class==Array
        text.each do |line|
          @connection.write(line+CRLF)
          LOG.info(@mail[:mail_id]) {"<-  #{line}"} if echo && LogReceiverConversation
        end
        return text.last[0]
      else
        @connection.write(text+CRLF)
        LOG.info(@mail[:mail_id]) {"<-  #{text}"} if echo && LogReceiverConversation
        return text[0]
      end
    rescue Errno::EPIPE => e
      LOG.error(@mail[:mail_id]) {"#{e.to_s}#{Unexpectedly}"}
      raise Quit
    rescue Errno::EIO => e
      LOG.error(@mail[:mail_id]) {"#{e.to_s}#{Unexpectedly}"}
      raise Quit
    end
  end

#-------------------------------------------------------#
#--- Receive text from the client ----------------------#
#-------------------------------------------------------#
  def recv_text(echo=true)
    begin
      Timeout.timeout(ReceiverTimeout) do
        begin
          temp = @connection.gets
          if temp.nil?
            LOG.warn(@mail[:mail_id]) {"The client abruptly closed the connection"}
            text = nil
          else
            text = temp.chomp
          end
        rescue Errno::ECONNRESET => e
          LOG.warn(@mail[:mail_id]) {"The client slammed the connection shut"}
          text = nil
        end
        LOG.info(@mail[:mail_id]) {" -> #{if text.nil? then "<eod>" else text end}"} \
          if echo && LogReceiverConversation
        puts " -> #{text.inspect}" if DisplayReceiverDialog
        return text
      end
    rescue Errno::EIO => e
      LOG.error(@mail[:mail_id]) {"#{e.to_s}#{Unexpectedly}"}
      raise Quit
    rescue Timeout::Error => e
      LOG.info(@mail[:mail_id]) {" -> <eod>"} if LogReceiverConversation
      return nil
    end
  end

#-------------------------------------------------------#
#--- Parse the email address and investigate it --------#
#-------------------------------------------------------#
  def psych_value(part, value)
    # these get set in both MAIL FROM and RCPT TO
    part[:value] = value
    part[:accepted] = false

    # check for the special case of "... <postmaster>"
    n = value.match(/^(.*)<(.+)>$/)
    if n && n[2].downcase=="postmaster"
      m = Array.new
      m[0] = n[0]
      m[1] = n[1]
      m[2] = PostMasterName
    else
      # parse out the name (if any) and the address (required)
      m = value.match(/^(.*)<(.+@.+\..+)>$/)
      # there MUST be a sender/recipient address
      return false if m.nil?
    end

    # break up the address
    part[:name] = m[1].strip
    part[:url] = url = m[2].strip

    # parse out the local-part and domain
    local_part, domain = url.split("@")
    part[:local_part] = local_part
    part[:domain] = domain

    # check the local part for validity?
#    Uppercase and lowercase English letters (a-z, A-Z)
#    Digits 0 to 9
#    Characters ! # $ % & ' * + - / = ? ^ _ ` { | } ~
#    Character . provided that it is not the first or last character,
#     and provided also that it does not appear two or more times consecutively.
    part[:dot_error] = true if (local_part[0]=='.' || local_part[-1]=='.' || local_part.index('..'))
    m = local_part.match(/^[a-zA-Z0-9\!\#\$%&'*+-\/?^_`{|}~]+$/)
    part[:char_error] = m.nil?

    # lookup the email to see if it's one of ours
    if respond_to?(:client_lookup)
      part[:mailbox_id], part[:owner_id], part[:delivery] = client_lookup(part[:url])
    else
      part[:mailbox_id], part[:owner_id], part[:delivery] = [nil, nil, :remote]
    end

    # get the MXs, if needed and if any --
    # if we deliver to a mailbox which has an owner_id,
    # delivery will be made with LMTP and no MXs will be needed
    part[:mxs] = mxs = if part[:owner_id].nil? then domain.dig_mxs else nil end

    return true
    #---------------------------------------------------------------------------------------#
    #--- WHAT WE KNOW AFTER PSYCH
    #--- 1. if the return value is true, the value has the correct form
    #--- 2. the url is in part[:url]
    #--- 3. the part[:local_part] and part[:domain] are have values
    #--- 4. the MXs, if any, are in part[:mxs] => { preference => [ [mx,ip], ... ], ... }
    #--- 5. if it's our member, part[:mailbox_id], part[:owner_id] have values
    #---------------------------------------------------------------------------------------#
  end

#-------------------------------------------------------#
#--- LOOP TO RECEIVE COMMANDS --------------------------#
#-------------------------------------------------------#

  def receive(local_port, local_hostname, remote_port, remote_hostname, remote_ip)
    # Start a hash to collect the information gathered from the receive process
    @mail = ItemOfMail::new
    @mail[:local_port] = local_port
    @mail[:local_hostname] = local_hostname
    @mail[:remote_port] = remote_port
    @mail[:remote_hostname] = remote_hostname
    @mail[:remote_ip] = remote_ip

    # start the main receiving process here
    @done = false
    @encrypted = false
    @authenticated = false
    @warning_given = false
    @mail[:encrypted] = false
    @mail[:authenticated] = nil
    send_text(connect_base)
    @level = 1
    response = "252 2.5.1 Administrative prohibition"
    begin
      begin
        break if @done
        text = recv_text
        # the  client closed the channel abruptly or we're forcing QUIT
        if (text.nil?) || @warning_given
          text = "QUIT"
          @contact.violation
        end
        # this handles an attempt to connect with HTTP
        if text.start_with?("GET")
          LOG.error(@mail[:mail_id]) {"An attempt was made to connect with a web browser"}
          @mail[:saved] = true # prevent saving
          raise Quit
        end
        # main command detect loop
        unrecognized = true
        Patterns.each do |pattern|
          break if pattern[0]>@level
          m = text.match(/^#{pattern[1].upcase}$/i)
          if m
            case
            when pattern[2]==:quit
              send_text(quit(m[1]))
            when pattern[0]>@level
              send_text("500 5.5.1 Command out of sequence")
            else
              response = send(pattern[2], m[1])
              @contact.violation if send_text(response)=='5'
            end
            unrecognized = false
            break
          end
        end
        if unrecognized
          response = "500 5.5.1 Unrecognized command #{text.inspect}, incorrectly formatted command, or command out of sequence"
          @contact.violation
          send_text(response)
        end
      rescue =>e #OpenSSL::SSL::SSLError => e
        LOG.error(@mail[:mail_id]) {"SSL error: #{e.to_s}"}
        e.backtrace.each { |line| LOG.error(@mail[:mail_id]) {line} }
        @done = true
      end until @done
    rescue => e
      LOG.fatal(@mail[:mail_id]) {e.to_s}
      exit(1)
    end

    # print the intermediate structure into the log (for debugging)
    (LOG.info(@mail[:mail_id]) { "Received Mail:\n#{@mail.pretty_inspect}" }) if DumpMailIntoLog

  ensure
    # make sure the incoming email is saved, in case there was a receive error;
    # otherwise, it gets saved just before the "250 OK" in the DATA section
    if !@mail[:saved]
      LOG.error(@mail[:mail_id]) {"#{@mail[:mail_id]} was not received completely. Saving the partial copy to queue."}

      # the email is faulty--save for reference
      case
      when !@mail.insert_parcels
        LOG.error(@mail[:mail_id]) {"#{ServerName} error: unable to save packet id=#{@mail[:mail_id]}"}
      when !@mail.save_mail_into_queue_folder
        LOG.error(@mail[:mail_id]) {"#{ServerName} error: unable to save queue id=#{@mail[:mail_id]}"}
      end
    end

    # run the mail queue queue runner now, if it's not running already
    ok = nil
    File.open(LockFilePath,"w") do |f|
      ok = f.flock( File::LOCK_NB | File::LOCK_EX )
      f.flock(File::LOCK_UN) if ok
    end
    if ok
      pid = Process::spawn("#{$app[:path]}/run_queue.rb")
      Process::detach(pid)
    end
  end

#-------------------------------------------------------#
#--- SMTP COMMAND HANDLING METHODS ---------------------#
#-------------------------------------------------------#

  def connect_base
    @contact = Contact.new(@mail[:remote_ip])
    raise StandardError.new("contact.new failed; see log") if @contact.nil?

    LOG.info(@mail[:mail_id]) {"New item of mail opened with id '#{@mail[:mail_id]}'"}

    if @contact.prohibited?
      # after the first denied message, we just slam the channel shut: no more nice guy
      LOG.warn(@mail[:mail_id]) {"Slammed connection shut. No more nice guy with #{@mail[:remote_ip]}"}
      raise Quit
    end

    if @contact.warning?
      # this is the first denied message
      @warning_given = true
      expires_at = @contact.violation.strftime('%Y-%m-%d %H:%M:%S %Z') # to kick it up to prohibited
      LOG.warn(@mail[:mail_id]) {"Access TEMPORARILY denied to #{@mail[:remote_ip]} (#{@mail[:remote_hostname]}) until #{expires_at}"}
      return "454 4.7.1 Access TEMPORARILY denied to #{@mail[:remote_ip]}: you may try again after #{expires_at}"
    end

    if respond_to?(:connect)
      msg = connect(value)
      return msg if !msg.nil?
    end

    # 8 bells and all is well
    @level = 1
    return "220 2.0.0 #{@mail[:local_hostname]} ESMTP RubyMTA 0.01 #{Time.new.strftime("%^a, %d %^b %Y %H:%M:%S %z")}"
  end

  def ehlo_base(value)
    @mail[:ehlo] = ehlo = {}
    ehlo[:value] = value

    # The email specs call for EHLO or HELO to be followed by a domain,
    # but this behavior can be turned off, if you want -- also, we look
    # to see if it's a real domain (well, duh! makes sense to do that)
    if EhloDomainRequired
      if value.index(".")
        ehlo[:domain] = domain = value.split(".").collect{ |item| item.strip }[-2..-1].join(".")
        ehlo[:ip] = ip = if EhloDomainVerifies then domain.dig_a else nil end
      else
        ehlo[:domain] = nil
        ehlo[:ip] = nil
      end

      return "501 5.5.1 Domain required after EHLO/HELO" \
        if ehlo.nil? || ehlo[:domain].nil?
      return "502 5.1.8 EHLO domain #{ehlo[:domain].inspect} was not found in the DNS system (maybe a fake domain?)" \
        if EhloDomainVerifies && ehlo[:ip].nil? && @mail[:local_port]==StandardMailPort
    end

    if respond_to?(:ehlo)
      msg = ehlo(value)
      return msg if !msg.nil?
    end

    text = "250-2.0.0 #{ServerName} Hello"
    text << " #{domain}" if domain
    text << " at #{ip}" if ip
    @level = 2
    return [text, "250-AUTH PLAIN", "250-STARTTLS", "250 HELP"]
  end

#-------------------------------------------------------#
#--- Sender --------------------------------------------#
#-------------------------------------------------------#
  def mail_from_base(value)
    @mail[:mailfrom] = from = {}
    @mail[:rcptto] = []
    from[:accepted] = false
    ok = psych_value(from, value)

    # these criteria MUST be met for any sender
    return "550 5.1.7 '#{from[:value]}' No proper sender (<...>) on the MAIL FROM line" if !ok

    # we check to see if this is a reasonable MAIL FROM address, or garbage
    return "550-5.1.7 local part #{from[:local_part].inspect} cannot contain", \
           "550 5.1.7 beginning or ending '.' or 2 or more '.'s in a row" \
      if from[:dot_error]
    return "550-5.1.7 #{from[:local_part].inspect} can only", \
           "550 5.1.7 contain a-z, A_Z, 0-9, and !#\$%&'*+-/?^_`{|}~." \
      if from[:char_error]

    LOG.info(@mail[:mail_id]) {"Receiving mail from sender #{from[:url]}"}

    # Check to see if this sender is one of ours -- how that is done is up to you --
    # You must implement 'client_lookup(url)' where url is the full email address --
    # Also, members MUST use use authenticated email on the SubmissionPort to
    # submit mail; non-members MUST use non-authenticated email on the
    # StandardMailPort to submit mail
    if (from[:mailbox_id]) && (@mail[:local_port]!=InternalSubmitPort)
      # traffic is from our member
      return "556 5.7.27 #{ServerTitle} members must use port #{SubmissionPort} to send mail" \
        if @mail[:local_port]!=SubmissionPort
      return "556 5.7.27 Traffic on port #{SubmissionPort} must be authenticated (i.e., #{ServerTitle} client)" \
        if !@mail[:authenticated]
      return "556 5.7.27 Traffic on port #{SubmissionPort} must be encrypted" \
        if !@mail[:encrypted]
    else
      # traffic is from a non-member
      return "556 5.7.27 Non #{ServerTitle} members must use port #{StandardMailPort} to send mail" \
        if !from[:mailbox_id] && @mail[:local_port]!=StandardMailPort
    end

    if respond_to?(:mail_from)
      msg = mail_from(value)
      return msg if !msg.nil?
    end

    @level = 3
    from[:accepted] = true
    return "250 2.0.0 OK"
  end

#-------------------------------------------------------#
#--- Recipient -----------------------------------------#
#-------------------------------------------------------#
  def rcpt_to_base(value)
    @mail[:rcptto] ||= []
    @mail[:rcptto] << rcpt = {}
    rcpt[:accepted] = false
    ok = psych_value(rcpt, value)

    # these criteria MUST be met for any recipient
    if !ok
      rcpt[:message] = "'#{value}' No proper recipient (<...>) on the RCPT TO line"
      LOG.info(@mail[:mail_id]) {rcpt[:message]}
      return "550 5.1.7 #{rcpt[:message]}"
    end

    # use the rcpt_to(value) method in the configuration file to add
    # more rules for filtering recipients; psych_value will determine if
    # the recipient is a member, if you have a 'client_lookup(url)', as mentioned above
    if respond_to?(:rcpt_to)
      msg = rcpt_to(value)
      return msg if !msg.nil?
    end

    @contact.allow
    @level = 4
    rcpt[:accepted] = true
    return "250 2.0.0 ACCEPTED"
  end

#-------------------------------------------------------#
#--- Data ----------------------------------------------#
#-------------------------------------------------------#
  def data_base(value)
    @mail[:data] = body = {}

    # make sure that there is at least 1 recipient
    count = 0;
    @mail[:rcptto].each { |rcpt| count += 1 if rcpt[:accepted] }
    @mail[:recipients] = count
    return "500 5.0.0 There must be at least 1 acceptable recipient" if count==0

    # receive the body of the mail
    body[:value] = value # this should be nil -- no argument on the DATA command
    body[:text] = lines = []
    send_text("354 Enter message, ending with \".\" on a line by itself")
    LOG.info(@mail[:mail_id]) {" -> (email message)"} if LogReceiverConversation && !ShowIncomingData
    while true
      text = recv_text(ShowIncomingData)
      if text.nil? # the  client closed the channel abruptly
        @mail.add_block(nil, 5)
        break
      end
      break if text=="."
      lines << text
    end

    # hold the new headers here (insert them down below)
    new_headers = []

    # check DKIM signatures, if any
    pdkim = []
    ok, signatures = pdkim_verify_an_email(PDKIM_INPUT_NORMAL, lines)
    signatures.each do |signature|
      pdkim << (status = PdkimReturnCodes[signature[:verify_status]])
    end
    if !pdkim.empty?
      body[:pdkim] = pdkim
      LOG.info(@mail[:mail_id]) {"DKIM signatures (from last to first): #{body[:pdkim].inspect})"}
      new_headers << "DKIM-Status: #{body[:pdkim].inspect[1..-2]}" # strip off the '[]'
    end

    #Return-Path: <coco@tzarmail.com>
    new_headers << "Return-Path: <#{@mail[:mailfrom][:url]}>"

    #Delivered-To: <mike@tzarmail.com>
    new_headers << "Delivered-To: <#{@mail[:rcptto][0][:url]}>"
    @mail[:rcptto][1..-1].each do |rcpt|
      new_headers << "\t<#{rcpt[:url]}>"
    end

    #Received: from cpe-107-185-187-182.socal.res.rr.com ([::ffff:107.185.187.182])
    # by mail.tzarmail.com (RubyMTA 0.0.1) with ESMTP
    # (envelope from <coco@tzarmail.com>)
    # id 1dYwrI-0iDWWN-0y; Sat, 22 Jul 2017 16:02:24 +0000
    new_headers << "Received: from #{@mail[:remote_hostname]} ([#{@mail[:remote_ip]}])"
    new_headers << "\tby #{@mail[:local_hostname]} (RubyMTA #{VERSION}) with ESMTP"
    new_headers << "\t(envelope from <#{@mail[:mailfrom][:url]}>)"
    new_headers << "\tid #{@mail[:mail_id]}; #{@mail[:time]}"

    # insert the new headers into the message text
    new_headers.reverse.each { |hdr| @mail[:data][:text].insert(0,hdr) }

    # always add a DKIM signature which will include our headers
    if $app[:dkim] && !@mail[:dkim_added]
      ok, signed_message = pdkim_sign_an_email(PDKIM_INPUT_NORMAL, ServerName, 'key', $app[:dkim], PDKIM_CANON_SIMPLE, PDKIM_CANON_SIMPLE, @mail[:data][:text])
      if ok==PDKIM_OK
        @mail[:data][:text] = signed_message
        @mail[:dkim_added] = true
      else
        LOG.info(@mail[:mail_id]) {"Unsuccessful at signing #{mail[:id]} to #{host}"}
      end
    end

    # parse the headers for easier inspection, if any
    @mail.parse_headers
    @level = 1

    if respond_to?(:data)
      msg = data(value)
      return msg if !msg.nil?
    end

    #-------------------------------------------------------#
    #--- EMail queueing here -------------------------------#
    #-------------------------------------------------------#
    LOG.info(@mail[:mail_id]) {"#{@mail[:mail_id]} accepted with #{count} recipient#{if count>1 then 's' end}"}

    # the email appears good, queue it
    @mail[:accepted] = true
    case
    when !@mail.insert_parcels
      "500 5.0.0 #{ServerName} error: unable to save packet id=#{@mail[:mail_id]}"
    when !@mail.save_mail_into_queue_folder
      "500 5.0.0 #{ServerName} error: unable to save queue id=#{@mail[:mail_id]}"
    else
      "250 2.0.0 OK id=#{@mail[:mail_id]}"
    end
  end

#-------------------------------------------------------#
#--- Reset ---------------------------------------------#
#-------------------------------------------------------#
  def rset_base(value)
    if respond_to?(:rset)
      msg = rset(value)
      return msg if !msg.nil?
    end

    @level = 0
    return "250 2.0.0 Reset OK"
  end

  def vfry_base(value)
    # SMTP includes commands called "VRFY" and "EXPN" which do exactly what verification services offer.
    # While those two functions are technically different, they both reveal to a third party whether email
    # addresses exist in the server's userbase. Nearly every Postmaster (mail server administrator) on the
    # Internet has turned off VRFY and EXPN due to abuse by spammers trying to harvest addresses, as well
    # as a general security and privacy measure required by most network's operational policies. In fact,
    # since about 1999 or before, all mail servers are installed with those off by default. That should
    # give a clear indication to email verifiers about the opinion of Postmasters of the service they
    # intend to offer. Doing verification against systems that have disabled those functions, whether
    # successful or not, constitutes an attempted breach of the receiver's security policies and may be
    # considered a hostile act by site administrators. Sending high volumes of verification probes without
    # an attempt to actually send an email will often trigger filters or firewalls, thus invalidating the
    # data and impairing future verification accuracy.
    # -- http://www.spamhaus.org/news/article/722/on-the-dubious-merits-of-email-verification-services
    #
    # What this means for us is: if a spammer sends spam and we try to validate the sender's email
    # address, or bounce the message, and it's a SPAMHAUS or other blacklist company's trap address,
    # *WE* will be blacklisted. So we don't use VFRY or EXPN, and don't use a EHLO, MAIL FROM, RCPT TO,
    # QUIT sequence either. The takeaway here: thanks to spammers and Spamhaus, one can't verify a
    # sender's or recipient's address safely.

    if respond_to?(:vfry)
      msg = vfry(value)
      return msg if !msg.nil?
    end

    return "252 2.5.1 Administrative prohibition"
  end

  def expn_base(value)
    if respond_to?(:expn)
      msg = expn(value)
      return msg if !msg.nil?
    end

    return "252 2.5.1 Administrative prohibition"
  end

  def help_base(value)
    if respond_to?(:help)
      msg = help(value)
      return msg if !msg.nil?
    end

    return "250 2.0.0 QUIT AUTH, EHLO, EXPN, HELO, HELP, NOOP, RSET, VFRY, STARTTLS, MAIL FROM, RCPT TO, DATA"
  end

  def noop_base(value)
    if respond_to?(:noop)
      msg = noop(value)
      return msg if !msg.nil?
    end

    return "250 2.0.0 OK"
  end

  def quit(value)
    @done = true
    if (@mail[:saved].nil?) && (@contact.violations? == 0)
      LOG.warn(@mail[:mail_id]) {"Quitting before a message is finished is considered a violation"}
      @contact.violation
    end
    return "221 2.0.0 OK #{ServerName} closing connection"
  end

  # This method MUST be supplemented to use AUTH -- if the authentication
  # succeeds, a "235 2.0.0 Authentication succeeded" message should be
  # returned; otherwise a "530 5.7.8 Authentication failed" error should
  # be returned
  def auth_base(value)
    if respond_to?(:auth)
      msg = auth(value)
      return msg if !msg.nil?
    end

    return "504 5.7.4 authentication mechanism not supported"
  end

  # These are not overrideable

  def starttls(value)
    send_text("220 2.0.0 TLS go ahead")
    LOG.info(@mail[:mail_id]) {"<-> (handshake)"} if LogReceiverConversation
    @connection.accept
    @encrypted = true
    @mail[:encrypted] = true
    return nil
  end

  def timeout(value)
    @done = true
    return ("500 5.7.1 #{"<mail id>"} closing connection due to inactivity--%s was NOT saved")
  end

end
