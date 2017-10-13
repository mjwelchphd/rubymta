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
