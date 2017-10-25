# v0.0.12

* Fixed the `send_text` in `QueueRunner` to not echo the data into the log when `LogQueueRunnerConversation` is set to `true`.
* Changed the text of the `-< (email message)` in Receiver to be `-> (data)` to match the QueueRunner class.


# v0.0.11

* Changed the STARTTLS to return a 500 error and continue processing. Before this change, it just erred out and closed the port with no feedback to the client. Because this error returns a 500 level error, the client is (ideally) expected to quit or restart the attempt from the beginning (at EHLO).
* if `e` is in a string like so: `"... #{e} ..."`, it doesn't require a `.to_s` because `#{}` does a `.to_s`. Changed all non-conforming strings to conform to this rule. Exception: where `e` is found in `rescue => e`, it takes the form `"... #{e.inspect} ..."` so that the actual error class will be displayed (so you'll know what specific rescue may be added).
* moved the initialization code for $ctx out of the `listening_thread` because it only needs to be set once, not for each port.


# v0.0.10

#### Warning: This version changes the queue file format. Previous queue files will *not* be compatible with this version.

* Added a test for valid UTF-8 encoding. On a 777 character Greek text, a `valid_encoding?` takes only in 3.6ns, so checking every line of text is not expensive.
* Revised the way emails are stored on disk: the main structure has the mail[:data][:text] removed and stored following the main structure. The reason for this change is that `eval` doesn't handle foreign UTF-8 character sequences well.
	- *__New Disk Format in `queue`:__*
	- Number of lines in main mail structure;
	- Main mail structure;
	- Unmodified text; this is added back to the main structure at `mail[:data][:text]` after the queue file is read.
* Added a Quit at the moment the connecting IP is placed under prohibition. The reason for this is that some senders don't stop sending when they receive a 500+ level message.
* If there is a `parcel` record, but no matching disk file, the parcel record is marked as delivery='none'. This prevents the QueueRunner from looping when an undelivered queue file is manually deleted.
* Added checks at the end of delivery in QueueRunner to test for the message level (should be 200+ if accepted).
* Added another check for the client abruptly closing the connection.
* Added '=' to the list of acceptable characters in a local part of an email address.

# v0.0.9
* Added a `rescue OpenSSL::SSL::SSLError` to catch sender certificate violations.
* Added a `LogLevel` into the Config file (config.rb) to control the logger output. I use LOGGER::INFO as my default.
* Changed the log message that the SqLite3 database is open to a `debug` level.

# v0.0.8

* No changes. I didn't properly rebuild the gem in v0.0.7.


# v0.0.7

* In `Receiver#starttls`  I added a `begin` block to catch errors I believe are caused by spammers sending random data as a certificate. It's open at this moment, `rescue => e`, but as soon as I discover what the spammers are doing, I'll tighten this up by specifying the proper exception.
* I modified the "authentication mechanism not supported" message to add "use TLS and PLAIN." The LOGIN authentication will be added eventually, but it has been replaced by TLS+PLAIN in practice. The EHLO response specifies that only PLAIN is accepted, so if a sender uses LOGIN, it's not a commercial server, but a spammer.
* The README.md was updated with the app I use to drive queue_runner.


# v0.0.6

* Replaced a call to a legacy method 'add_block' to the proper method 'violation'. This bug only activated if the sender slammed the connection shut during the data block transfer.
* Fixed a bug causing a run-time error when the sender sent an email, and slammed the connection shut after issuing the DATA command.


# v0.0.5

* Changed the code that enforces the rule that: external non-member mail has to come in on port 25; external member mail has to come in on port 587; and internal mail can come in on port 465. Port 465 is open, i.e., requires no authentication nor encryption. (You should use iptables to be sure port 465 is not open to the Internet.


# v0.0.4

* Updated the gem to reflect changes in Ruby Sequel v4.40.0.


# v0.0.3

* Added a `contact_id` firld to the `parcels` table so that the parcels can be related back to the IP that sent them, irrespective of the domain names presented. The contact IP is an absolute quantity, and one of the first ones we get, so it forms the cornerstone of the data structure.


# v0.0.2

* Added code to make sure RubyMTA quits on the next command after a violations warning is given.
* Added code to detect the GET command from an attempt to connect with a web browser.
* Made corrections to the README.md file.
* removed the gmta-dev.db test file. A new one will be created when RubyMTA starts running.
* Added the method `send_local_alert` method which simply places the message into the local delivery system (Dovecot, in my case). This method provides a way to send an alert when there is a failure that requires someone's attention right away.
* Fixed a bug in queue_runner where it coded a partial item of mail as 'local'. Now, if the @mail[:accepted] flag is not true, the mail destination in the packet is set to 'none' as it should be.
* Made a change such that all packets coded as :delivery=>'none' also have the :delivery_at=>Time.now.


# v0.0.1

* Initial load. See the README.md for details.
