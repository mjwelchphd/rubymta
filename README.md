# Ruby Mail Transport Agent (RubyMTA)

RubyMTA is a complete basic email server in a gem. It's completely written in Ruby and the configuration file is just a Ruby Module. RubyMTA is configured by setting a list of values, as well as extending the basic handlers for each of the SMTP handler methods. Because it's Ruby, you can override any method in the gem, if you need to.

It comes with a sample test configuration and a set of Bacon tests. (Requires installing the Bacon gem.)

## Disclaimer

This is experimental code which I've written for my own use. I'm happy to share it, and if it's useful to you in any way, I'm pleased about that. If you want to ask me questions, email me at mjwelchphd@gmail.com and I'll answer questions for free; but if you want me to write software for you, I'm available for hire.

There's a lot that still needs to be added, like bounce messages and forwarding. Also, while you can use `sqlite3 <database-name>` to view the database, you'll need to build yourself a 'control panel' to allow users to view and edit the database tables. It's almost a sure thing you'll be using a bigger database, like MySQL, Postgre, or Oracle, to store usernames and other data for your project, so you probably already hove some code for that. I implemented a control panel in a web site for the two SqLite3 tables, plus MySQL for the rest of the tables I use.

I'll make an effort to minimize the impact of future changes on the existing model, i.e., I'll try not to break anyone's working configuration, but I don't guarantee it. When software is this new and experimental, sometimes minor programming model changes are necessary.

If you want to contribure, go to GitHub and fork a copy. Submit pull requests for your changes, but remember, if you email me at mjwelchphd@gmail.com first, and make a proposal, I'll let you know ahead of time if I'll accept your PR. It could save you some time, and I may be able to give you some time-saving advice.

I wrote this gem because I've been using Exim4 (which is a an excellent general purpose mail transport agent), but Exim4 doesn't do a lot of things I want to do with an MTA. Exim4 and other general purpose MTAs were built from legacy rules and legacy code which, _in my opinion_, are now outdated. If Exim4 or other MTA you use does everything you want it to do, you should probably stick with it. I need to move into the future of email, so here I am.

RubyMTA is Ruby code. Do whatever you want with it. The only limitation is your imagination. It uses the outstanding Ruby gem _Sequel_, which Jeremy Evans calls [Sequel: The Database Toolkit for Ruby.](http://sequel.jeremyevans.net/) Sequel makes database operations a non-issue in programming, and it allows you to use almost any popular database available.

RubyMTA uses Ruby Hash objects to store items of email and other data, as Matz intended. You can add elements to an item of mail to suit your taste, and they are persistent. Once added, they can be accessed or manipulated anywhere until you delete them. It makes the code simple to read and understand. (I hate code only the author can read.)

Ayn Rand wrote in her novel, _Anthem_, “The secrets of this earth are not for all men to see, but only for those who will seek them.” If you want to know the details, study the code. It's not rocket science.

I use Linux Mint, but any linux will work. I don't use Windows, so if you want to use this gem on Windows, any assistance I can give you will probably be limited (but ask anyways). Sorry.
  
### Features of the Server

* It can listen on any number of ports simultaneously. These are usually 25, 467, and 587, the standard mail ports, but you can use any ports you want, if you have a special use for them.
* The server can run in user space, or as root. If you want to use the standard mail ports, the server must run as root. The server can run as a daemon.
* When a connection is made to the server, the server starts a separate receiver process to handle it.
* When properly configured, the receiver processes will lose their root privileges immediately after creation. This is a security feature which protects the server.
* The receiver supports TLS (the STARTTLS verb in SMTP).
* The receiver supports full authentication, but you must choose the method.
* A log file is built in.
* RubyMTA uses an SqLite3 database for two tables it uses to manage the state of the MTA.
* RubyMTA uses the Sequel gem for an ORM, so RubyMTA will support a range of databases, like MySQL and Postgre.
* RubyMTA runs until terminated by a `KILL -INT <pid>` or `^C`.
* A set of DNS queries is built in. These are used by the receiver to collect information about the sender and recipient.
* A SMTP server tester (to see if a given MX has a live mail server running) is built in.
* A method to validate AUTH PLAIN (Linux CRYPT) hashes. It's generally accepted that AUTH LOGIN is not needed because the server supports TLS.

### Features of the Receiver

* The receiver has several measures built-in that are designed to defeat spammers. They will be explained further in the configuration section.
* The internal format of the email and all the data collected about it is a Ruby Hash. You can add additional data to the hash as you find necessary to program any special features you want.
* The receiver has some built-in rules (or filters, if you wish to look at them like that).
* You can (in your configuration) extend any of the SMTP verb methods to add additional rules, perform operations on the data, and save information in the mail object.
* This is Ruby, so you can override or extend anything. There are things you can do easily in Ruby that you can't do at all in Courier, Exim4, or Postfix.
* The receiver adds the standard headers upon receipt of an email:
    * Return-Path
    * Delivered-To
    * Received
    * DKIM-Signature (which includes the above)
* The design is based on the idea of doing enough work during reception, that delivery is almost assured. For example, if an email is directed to a client, i.e., _local_ delivery, we can make sure that the client exists before accepting the email from the sender. In the case of a remote delivery, the existence of the server can be verified before accepting the email.
    
### Features of the Queue Runner

* The method `QueueRunner#run_queue` reads the queue and sorts the emails by domain and recipient in order to deliver all the recipients for a a give domain in a single parcel.
* It can deliver locally via LMTP (for Dovecot) or remotely via a remote server.
* You can program your own app to use `queue_runner` or write your own queue runner.

### TODO!

* The queue runner is a very basic class. Bounce and forwarding need to be implemented. Since I add a rule to reject relays in my server, bounce messages only need to be delivered locally with LMTP. In a relaying server, bounce messages may be sent back to a remote sender; if that address is spoofed, and it turns out to be a trap address, your server will get blacklisted. Hence the rule: I don't relay. There is an example rule in the demo configuration which implements a "no relay" error message, and now you know why email admins don't allow relays anymore.

### The Server is an Excellent Example of SSL Sockets

Most of the posts on the Internet on how to use SSL Sockets **_are wrong!_** Study `server.rb` to see how it's done correctly.

### This Version is Considered a Basic, but Stable Release
This server has been tested by sending it over 23,000 spam emails. No faults were found. It's licensed under the MIT license, so technically, you're on your own. But practically, drop me an email at mjwelchphd@gmail.com if you need help with this. I want it to be useful, stable, and reliable.

### Receive Rules As Of This Writing

#### On Connect

* Access TEMPORARILY denied
If the number of violations is equal to `MaxFailedMsgsPerPeriod`. If the number of violation exceeds `MaxFailedMsgsPerPeriod`, the connection is slammed shut (closed without further warning).

#### On EHLO or HELO

* Domain required after EHLO/HELO
This error will be returned if the value part of the EHLO statement is left blank.
* EHLO domain ... was not found in the DNS system
This error means that a DNS lookup of the value part of the EHLO statement came back empty. (The domain name given in the value part was not legitimate.)

#### On MAIL FROM

* No proper sender ... on the MAIL FROM line
This error will be returned if the value part of the MAIL FROM statement does not contain a properly formatted value: i.e., optional-name <username@domain.ext>.
* Local part ... cannot contain ...
Either the usage of dots ('.') is wrong, or illegal characters were found. Legal characters for this MTA are a-z, A_Z, 0-9, and !#\$%&'*+-/?^_`{|}~.
* Members must use port ...
If a sender is found in the user database (the sender is a member), (s)he must use port ... to send an email.
* Traffic on port ... must be authenticated
Members must send emails on an authenticated, encrypted port.
* Traffic on port ... must be encrypted
Members must send emails on an authenticated, encrypted port.
* Non members must use port ...
Non-members may not use any port except the `StandardMailPort`.

#### RCPT TO

* No proper recipient ... on the RCPT TO line
This error will be returned if the value part of the RCPT TO statement does not contain a properly formatted value: i.e., optional-name <username@domain.ext>.

#### DATA

* There must be at least 1 acceptable recipient
This error will be returned if all the recipients in the RCPT TO lines were rejected.
* Error: unable to save packet id=...
This error will be returned if the write to the `packets` table fails.
* Error: unable to save queue id=...
This error will be returned if the ItemOfMail object could not be saved to the `queue` directory.

### The `contacts` Table

RubyMTA makes an entry into it's `contacts` table in the SqLite3 database every time there is a connection. It keeps track of the number of times a sender has connected, but more importantly, it counts the number of _violations_ and when `MaxFailedMsgsPerPeriod` is reached, RubyMTA refuses the connection with a warning message, and sets a lockout for `ProhibitedSeconds` seconds. If yet another connection is attempted during the lockout period, RubyMTA slams the connection shut until the lockout period has passed.

### The `parcels` Table

Every time a valid email is received, an entry is placed into the parcels table for each recipient of the given email. As emails are successfully delivered, the delivery time is put into the table for that recipient, along with the last server message. This table is used by the `queue_runner` to schedule delivery of mail. It's also useful to see why a parcel was undeliverable, in the case delivery fails.

This feature stops spammers and hackers from repeatedly connecting in an attempt to hack the server.

## How to Get the Gem

You can get the gem's source code on GitHub:
```bash
git clone https://github.com/mjwelchphd/rubymta.git
```

To update your copy, just use:
```bash
git pull
```

You can also get the gem on rubygems.org:
```bash
sudo gem install rubymta
```

You will also a few other gems:
```bash
sudo gem install bacon pdkim pretty_inspect unix-crypt
```

# Gem Dependencies
This gem requires the following (in alphabetical order):
```ruby
require "bacon"
require "base64"
require "etc"
require "logger"
require "openssl"
require "optparse"
require "ostruct"
require "pdkim"
require "pretty_inspect"
require "resolv"
require "sequel"
require "socket"
require "sqlite3"
require "timeout"
require "unix_crypt"
```
All of these packages are found in the Ruby Standard Library (stdib 2.2.2 at the time of this writing), except bacon, pdkim, pretty_inspect, and unix-crypt, which you will have to install. They are required in the gem itself, so you don't have to require them.

### The Working Demo

There is a working demo that you can configure to experiment with RubyMTA, or for your own setup. This demo program is a good place for you to start to build your own program. It's located inside the gem in a directory called "gmta."

Copy that to your own directory, and edit it according to the parameters below. Here's the configuration file I use for testing the gem:

```bash
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
      return "556 5.7.27 This server does not support relaying"
    end
    nil
  end

end
```

### Configuration Parameters

| Parameter | Description |
| --- | --- |
| ServerTitle | Choose an appropriate name, such as "ABC Company Mail Server" |
| ServerName | Use the server's *_domain_* name, i.e., `mail.abc.com`. |
| PostMasterName | Use the email address _to which the postmaster's mail should be directed_, i.e., `jim-malone@abc.com`.
| StandardMailPort | The standard mail port is 25. If you are testing, you might use a port like 2000 (which is above 1023 and doesn't require you to run the server as `root`. |
| InternalSubmitPort | The internal mail submission port is 467. If you are testing, you might use a port like 2001 (which is above 1023 and doesn't require you to run the server as `root`.  |
| SubmissionPort | The standard mail submission (for clients) port is 587. If you are testing, you might use a port like 2002 (which is above 1023 and doesn't require you to run the server as `root`.  |
| LocalLMTPPort | The port commonly used for internal submission (to Dovecot) is 24, but as long as you use the same port in Dovecot's configuration files, it doesn't matter what port you use. |
| UserName | Use the the login name under which the receiver will receive the email, once it is passed a connection from the server. This is optional if you are not going to run the MTA as root. |
| GroupName | Use the group name under which the receiver will receive the email, once it is passed a connection from the server. This is optional if you are not going to run the MTA as root. |
| LockFilePath | Use a name where the lock file will be located. It may be best to just follow the pattern. Make sure that if you run RubyMTA as root that the lock file is available to the UserName/GroupName also. |
| PrivateKey | This is the name of the private key file for encrypting/decrypting TLS. If you are not going to support TLS, this can be nil. |
| Certificate | This is the name of the certificate file for encrypting/decrypting TLS. If you are not going to support TLS, this can be nil. |
| S3DBPath | Use the name of the SqLite3 file which will contain the `contacts` and `parcels` tables used by the RubyMTA. The first time the server is started, if the file is not there, RubyMTA will create it and its tables. You can edit the database using the `sqlite3 <database>` command.
| LogPathAndFile | Use any location you want for the log file, but the log file _is not_ optional. Make sure that if you run RubyMTA as root that the log file is available to the UserName/GroupName also, or `run_queue` will fail.  |
| LogFileLife | See the `logger` ruby gem for acceptable values. |
| PidPath | Use any location you want, but make sure that if you run RubyMTA as root that the log file is available to the UserName/GroupName also. |
| ReceiverTimeout | The default value of 30 seconds is good. You can experiment with this value, but normally, you will have very few connections that will need to be timed out (just some wierd spammer thing, maybe). |
| RemoteSMTPPort | The standard mail port is 25. This is the port used by the `queue_runner` for outgoing remote SMTP mail. |
| ProhibitedSeconds | Use the number of seconds you want to lock out a badly behaved sender. I've seen spammers send messages as slowly as every 15 minutes, so I used 3600 seconds as a default. |
| MaxFailedMsgsPerPeriod | Use the number of violations a sender can have before getting rejected with a warning. On the `MaxFailedMsgsPerPeriod`th + 1 connection, RubyMTA will slam the port shut without a warning to the sender. After the `ProhibitedSeconds` lockout period has passed without a connection attempt, the prohibition is removed. |
| ShowIncomingData | If true, logs the incoming data in the DATA section of an email. This can produce giant logs, and only should be used for debugging. Set to false. |
| EhloDomainRequired | If true, the receiver will make sure there is a domain name following the EHLO (or HELO) verb. This should be set to `true` because email rules require it. |
| EhloDomainVerifies | Validate the domain name given in the EHLO (or HELO) verb using DNS. |
| DumpMailIntoLog | If true, this dumps the ItemOfMail hash into the log for debugging. It should only be used for debugging. The dump is identical to the data stored in the email in the queue directory. |
| DisplayReceiverDialog | This variable is like LogReceiverConversation, but displays on the screen rather than go to the log. |
| LogReceiverConversation | If true, the dialog between the sender and the receiver is logged. This flag is usually used for debugging, but it is also useful to see the dialog when an attacker is trying to connect with an unknown command sequence. |
| MessageIdBase | Linux filenames are case sensitive, so this can be set to 62. OSX and Cygwin are not, so this must be set to 36. You can set it to 36 for Linux, but that would be ugly. |
| MailQueue | Use the path of the directory where ItemOfMails will be stored. |
| QueueRunnerTimeout | The default value of 30 seconds is good, but you can experiment with this value if you are sending remote mail, and having trouble with a particular network route timing out. |
| DisplayQueueRunnerDialog | This variable is like LogQueueRunnerConversation, but displays on the screen rather than go to the log. |
| LogQueueRunnerConversation | If true, the dialog between the queue_runner and Dovecot or the remote server is logged. This flag is usually used for debugging, but it is also useful to see the dialog when you are having trouble communicating with a particular remote server. |
| DKIMPrivateKeyFile | Use the path and name of the _private_ DKIM key, if you want to support DKIM, or nil if not. (The public key goes into the server's DNS records.)

### Configuration Extensions

Each verb (EHLO, MAIL FROM, etc.) can have an _extension_. After the built in processing is complete, if you have an extension method in your configuration file, it will be called. It must return either nil or a message that will be returned by the verb.

For example, if I want to check for a relay (remote sender plus remote recipient), I can use a method in the `class Receive` in my configuration file, like the one in the example above.

There are two required extensions, `client_lookup` and `auth`.

The `client_lookup` extension looks in the user list (which may be any source of your choosing), and returns three values: (1) the record ID for the mailbox, and (2) the record ID of the owner of the mailbox, and (3) the value _:local_ or _:remote_, as appropriate. This is by `queue_runner` to deliver the email.

The `auth` extension validates the user's password. Normally, a _client_ must log into the server to _send_ mail. The reason is to prevent spoofing. *__This basic MTA does not contain the rules to enforce this. It is left to the programmer to program those and any other rules he wants.__* Use the example to see how this is usually done. Note that a dummy list is inserted into the demo for testing.

<hr/><center>Fin.</center>
