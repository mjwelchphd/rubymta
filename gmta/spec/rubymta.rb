require "bacon"
require 'sequel'
require "sqlite3"

Sender = "mjwelchphd@gmail.com"
Recipient = "coco@tzarmail.com"
S3DBPath = "/home/devel/rubymta/gmta/gmta-dev.db"
RemoteIP = "2001:4800:7811:513:be76:4eff:fe04:f0b4"
EhloDomainRequired = true


# Open the sqlite3 database for rubymta use
S3DB = Sequel.connect("sqlite:///#{S3DBPath}")

# swaks -tls -s mail.tzarmail.com:25 -t mike@tzarmail.com -f mjwelchphd@gmail.com --ehlo bluecrapduck345at789zappo.com

# {:id=>5, :remote_ip=>"::ffff:107.185.187.182", :hits=>142, :locks=>1, :violations=>1,
#  :expires_at=>2017-07-07 22:44:52 +0000, :created_at=>2017-05-22 19:58:51 +0000,
#  :updated_at=>2017-07-07 22:41:11 +0000}
ds = S3DB[:contacts].where(:remote_ip=>RemoteIP)

describe "Rubymta Gem 'contacts table' Tests" do

  # be sure we can set/reset the contacts table
  it "reset the test contact record" do
    ds.update(:locks=>0, :violations=>0, :expires_at=>Time.now)
    rs = ds.select(:locks, :violations).first
    (rs.inspect).should.be.equal "{:locks=>0, :violations=>0}"
  end

  # send a simple email just as a sanity check
  it "the MTA should accept a simple email" do
    response = `swaks -tls -s mail.tzarmail.com:25 -t #{Recipient} -f #{Sender}`
    ok = response.index("250 2.0.0 OK id=")
    ok.should.not.equal 0
  end

  # 1st violation -- reject a relay attempt
  it "1st violation -- reject a relay attempt" do
    response = `swaks -tls -s mail.tzarmail.com:25 -t mike.w@tzarmail.com -f #{Sender}`
    ok = response.index("556 5.7.27 Czar Mail does not support relaying")
    ok.should.not.equal 0
  end

  # the first failure should have set violations=1
  it "should have 1 violation" do
    rs = ds.select(:locks, :violations).first
    (rs.inspect).should.be.equal "{:locks=>0, :violations=>1}"
  end

  # 2nd violation -- reject a relay attempt
  it "2nd violation -- reject a relay attempt" do
    response = `swaks -tls -s mail.tzarmail.com:25 -t mike.w@tzarmail.com -f #{Sender}`
    ok = response.index("556 5.7.27 Czar Mail does not support relaying")
    ok.should.not.equal 0
  end

  # the second failure should have set violations=2
  it "should have 2 violations" do
    rs = ds.select(:locks, :violations).first
    (rs.inspect).should.be.equal "{:locks=>0, :violations=>2}"
  end

  # 3rd violation -- reject a relay attempt
  it "3rd violation -- reject a relay attempt" do
    response = `swaks -tls -s mail.tzarmail.com:25 -t mike.w@tzarmail.com -f #{Sender}`
    ok = response.index("556 5.7.27 Czar Mail does not support relaying")
    ok.should.not.equal 0
  end

  # the third failure should have set violations=3
  it "should have 3 violations" do
    rs = ds.select(:locks, :violations).first
    (rs.inspect).should.be.equal "{:locks=>0, :violations=>3}"
  end

  # the 4th violation should respond with a message and set the lock
  it "the 4th violation should set the lock" do
    response = `swaks -tls -s mail.tzarmail.com:25 -t mike.w@tzarmail.com -f #{Sender}`
    ok = response.index("454 4.7.1 Access TEMPORARILY denied")
    ok.should.not.equal 0
  end

  # the fourth failure should have set violations=4 and locks=1
  it "should have 4 violations and 1 lock" do
    rs = ds.select(:locks, :violations).first
    (rs.inspect).should.be.equal "{:locks=>1, :violations=>4}"
  end

  # the 5th (and following) violations should have to door slammed
  it "5th violation -- slam the connection shut" do
    response = `swaks -tls -s mail.tzarmail.com:25 -t mike.w@tzarmail.com -f #{Sender}`
    ok = response.end_with?("=== Connected to mail.tzarmail.com.\n")
    ok.inspect.should.equal "true"
  end

  # the 5th failure doesn't change the lock or violations
  it "5th failure should still have 4 violations and 1 lock" do
    rs = ds.select(:locks, :violations).first
    (rs.inspect).should.be.equal "{:locks=>1, :violations=>4}"
  end

end

describe "Rubymta Gem EHLO Tests" do

  if EhloDomainRequired
    ds.update(:locks=>0, :violations=>0, :expires_at=>Time.now)
    it "EHLO requires a domain" do
      response = `swaks -tls -s mail.tzarmail.com:25 -t #{Recipient} -f #{Sender} --ehlo 'not-valid-domain'`
      ok = response.index("454 4.7.1 Access TEMPORARILY denied")
      ok.should.not.equal 0
    end

    ds.update(:locks=>0, :violations=>0, :expires_at=>Time.now)
    it "the EHLO domain must be found in the DNS" do
      response = `swaks -tls -s mail.tzarmail.com:25 -t #{Recipient} -f #{Sender} --ehlo 'domain-not-in-dns.lost'`
      ok = response.index("was not found in the DNS system")
      ok.should.not.equal 0
    end
  end

end

describe "Rubymta Gem MAIL FROM Tests" do

  ds.update(:locks=>0, :violations=>0, :expires_at=>Time.now)
  it "the MAIL FROM line must have a sender" do
    response = `swaks -tls -s mail.tzarmail.com:25 -t #{Recipient} -f mr-nobody`
    ok = response.index("No proper sender (<...>) on the MAIL part line")
    ok.should.not.equal 0
  end

  ds.update(:locks=>0, :violations=>0, :expires_at=>Time.now)
  it "the MAIL FROM sender cannot have '.' as the first character" do
    response = `swaks -tls -s mail.tzarmail.com:25 -t #{Recipient} -f .dennis@gmail.com`
    ok = response.index("550 5.1.7 beginning or ending '.' or 2 or more '.'s in a row")
    ok.should.not.equal 0
  end

  ds.update(:locks=>0, :violations=>0, :expires_at=>Time.now)
  it "the MAIL FROM sender cannot have '.' as the last character" do
    response = `swaks -tls -s mail.tzarmail.com:25 -t #{Recipient} -f dennis.@gmail.com`
    ok = response.index("550 5.1.7 beginning or ending '.' or 2 or more '.'s in a row")
    ok.should.not.equal 0
  end

  ds.update(:locks=>0, :violations=>0, :expires_at=>Time.now)
  it "the MAIL FROM sender cannot have two '.'s in a row" do
    response = `swaks -tls -s mail.tzarmail.com:25 -t #{Recipient} -f dennis..george@gmail.com`
    ok = response.index("550 5.1.7 beginning or ending '.' or 2 or more '.'s in a row")
    ok.should.not.equal 0
  end

  # send a MAIL FROM <a member>
  ds.update(:locks=>0, :violations=>0, :expires_at=>Time.now)
  it "the MTA expects member mail on port 587" do
    response = `swaks -tls -s mail.tzarmail.com:25 -t #{Sender} -f #{Recipient}`
    ok = response.index("556 5.7.27 Czar Mail members must use port 587 to send mail")
    ok.should.not.equal 0
  end

  ds.update(:locks=>0, :violations=>0, :expires_at=>Time.now)
  it "traffic on port 587 must be authenticated" do
    response = `swaks -tls -s mail.tzarmail.com:587 -t #{Sender} -f #{Recipient}`
    ok = response.index("556 5.7.27 Traffic on port 587 must be authenticated")
    ok.should.not.equal 0
  end

  ds.update(:locks=>0, :violations=>0, :expires_at=>Time.now)
  it "traffic on port 587 needs to be encrypted" do
    response = `swaks -a PLAIN -s mail.tzarmail.com:587 -t #{Sender} -f #{Recipient} < spec/coco`
    ok = response.index("556 5.7.27 Traffic on port 587 must be encrypted")
    ok.should.not.equal 0
  end

  # send mail from a <non-member>
  ds.update(:locks=>0, :violations=>0, :expires_at=>Time.now)
  it "the MTA expects non-member mail on port 25" do
    response = `swaks -tls -s mail.tzarmail.com:587 -t #{Recipient} -f #{Sender}`
    ok = response.index("556 5.7.27 Non Czar Mail members must use port 25 to send mail")
    ok.should.not.equal 0
  end

end

describe "Rubymta Gem RCPT TO Tests" do

  ds.update(:locks=>0, :violations=>0, :expires_at=>Time.now)
  it "the RCPT TO line must have a recipient" do
    response = `swaks -tls -s mail.tzarmail.com:25 -t mrs-nobody -f #{Sender}`
    ok = response.index("No proper recipient (<...>) on the RCPT part line")
    ok.should.not.equal 0
  end

end

# There is only 1 unreachable test in DATA (I think it's unreachable),
# so the DATA tests here have been omitted.
