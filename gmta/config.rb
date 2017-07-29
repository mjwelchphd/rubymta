# There should be no modifiable files in the gem itself
# InternalSubmitPort should not be visible outside the local env
# add pdkim gem

module Config
  # server configuration
  ServerTitle = "Test Mail"
  ServerName = "mail.tzarmail.com" # server name used in messages and EHLO
  PostMasterName = "postmaster@tzarmail.com"
  StandardMailPort = '25' #'25'--non client must come in here
  InternalSubmitPort = '467' #'467'--internal port
  SubmissionPort = '587' #'587'--client must come in here
#  StandardMailPort = '2000' #'25'--non client must come in here
#  InternalSubmitPort = '2001' #'467'--internal port
#  SubmissionPort = '2002' #'587'--client must come in here

  LocalLMTPPort = '24' #'24'--for sending to dovecot
  ListeningPorts = [StandardMailPort,InternalSubmitPort,SubmissionPort]
  UserName = "devel" # must be present if rubymta run as root
  GroupName = "devel" # must be present if rubymta run as root
#  UserName = nil # must be present if rubymta run as root
#  GroupName = nil # must be present if rubymta run as root

  LockFilePath = "#{$app[:path]}/gmta.lock"
  PrivateKey = "#{$app[:path]}/gmta.key" # filename or nil TODO! all $app[:path] have to come from the $app[:dir]
  Certificate = "#{$app[:path]}/gmta.crt" # filename or nil
#  PrivateKey = nil
#  Certificate = nil
  S3DBPath = "#{$app[:path]}/gmta-dev.db"
  LogPathAndFile = "/var/log/rubymta/rubymta.log" # log file location
  LogFileLife = "daily" # log rotation control
  PidPath = "/var/run/rubymta" # path to the directory where rubymta.pid will be stored

  # receiver configuration
  ReceiverTimeout = 30 # seconds
  RemoteSMTPPort = 25 # port 25 is the outgoing submitter port
  ProhibitedSeconds = 3600 # number of seconds prohibition is enforced
  MaxFailedMsgsPerPeriod = 3 # number of violations before IP is prohibited
  ShowIncomingData = false # true for testing--creats giant logs for giant emails
  EhloDomainRequired = true # the email rules require this
  EhloDomainVerifies = true # the domain must exist in the DNS system
  DumpMailIntoLog = false # true for testing--creates giant logs
  DisplayReceiverDialog = true # this displays the received dialog on the display
  LogReceiverConversation = true # enables the logging of the incoming conversation

  # item of mail configuration
  MessageIdBase = 62 # 62 for Linux, 36 for OSX and Cygwin
  MailQueue = "#{$app[:path]}/queue"

  # transporter configuration
  QueueRunnerTimeout = 30
  DisplayQueueRunnerDialog = true  # this displays the transported dialog on the display
  LogQueueRunnerConversation = false # enables the logging of the outgoing conversation
  DKIMPrivateKeyFile = "dkim.private.key"
end

# the test password is 'my-password' --
# this should be replaced by a database lookup
Users = {'coco@tzarmail.com'=>{:id=>1, :passwd=>"$5$BsHk6IIvndgdBmo9$iuO6WMaXzgzpGmGreV4uiH72VRGG1USNK/e5tL7P9jC"},
          'mike@tzarmail.com'=>{:id=>2, :passwd=>"$5$BsHk6IIvndgdBmo9$iuO6WMaXzgzpGmGreV4uiH72VRGG1USNK/e5tL7P9jC"}}

class Receiver

#*************************************************************************
#*** This is a special override which always returns 3 arguments       ***
#*** They are: :id, :owner_id, and either :local or :remote depending  ***
#*** on whether the email belongs to us or not. In the case that the   ***
#*** name is not found, it returns [nil, nil, :remote]                 ***
#*************************************************************************

  def client_lookup(email)
    # check to see if this email is a client and
    # get both the mailbox_id and owner_id for use later --
    # the question, "is it a client?" can be answered
    # like: if @mail[:mailfrom][:mailbox_id] ...
    if user = Users[email]
      [user[:id],1,:local]
    else
      [nil, nil, :remote]
    end
  end

#*************************************************************************
#*** The remaining overrides get the value (the received command line) ***
#*** and return either an error string or array of strings             ***
#*************************************************************************

  def auth(value)
    auth_type, auth_encoded = value.split
    # auth_encoded contains both username and password
    case auth_type.upcase
    when "PLAIN"
      # get the password hash from the database
      username, ok = auth_encoded.validate_plain do |username|
        # the password hash is for "my-password"
        # this should be replaced by a database lookup
        passwd = Users[username][:passwd]
      end
      if ok
        @mail[:authenticated] = username
        return "235 2.0.0 Authentication succeeded"
      else
        return "530 5.7.8 Authentication failed"
      end
    end
    nil
  end

  def rcpt_to(value)
    # this is a sample rule that disallows relaying
    from = @mail[:mailfrom]
    rcpt = @mail[:rcptto].last
    if from[:owner_id].nil? && rcpt[:owner_id].nil?
      @contact.violation
      LOG.info("%06d"%Process::pid) {"Mail from #{from[:url]} to #{rcpt[:url]} was rejected because it was a relay"}
      return "556 5.7.27 Czar Mail does not support relaying"
    end
    nil
  end

end

