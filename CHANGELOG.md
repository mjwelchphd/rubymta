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
