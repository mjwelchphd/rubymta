require_relative 'base-x'
require_relative 'deepclone'
require 'open3'
require "./config" # config.rb is in user space

class SaveError < StandardError; end

class ItemOfMail < Hash

  include Config

  def initialize(mail=nil)
    if mail
      # clone, if a mail is provided
      mail.each {|k,v| self[k]=v.deepclone }
    else
      # assign a new message id for new mail
      new_id = []
      new_id[0] = Time.now.tv_sec.to_b(MessageIdBase)
      new_id[1] = ("00000"+(2176782336*rand).to_i.to_b(MessageIdBase))[-6..-1]
      new_id[2] = ("00"+(Time.now.usec/1000).to_i.to_b(MessageIdBase))[-2..-1]
      self[:mail_id] = new_id.join("-")
    end

    # always set the time of creation
    self[:time] = Time.now.strftime("%a, %d %b %Y %H:%M:%S %z")
    self[:saved] = nil
    self[:accepted] = nil
  end

  def parse_headers
    self[:data][:headers] = {}
    header = ""
    self[:data][:text].each do |line|
      case
      when line.nil?
        break
      when line =~ /^[ \t]/
        header << String::new(line)
      when line.empty?
        break
      when !header.empty?
        keyword, value = header.split(":", 2)
        self[:data][:headers][keyword.downcase.gsub("-","_").to_sym] = value.strip if !value.nil?
        header = String::new(line)
      else
        header = String::new(line)
      end
    end
    if !header.empty?
      keyword, value = header.split(":", 2)
      self[:data][:headers][keyword.downcase.gsub("-","_").to_sym] = if !value.nil? then value.strip else "" end
    end
  end

  def insert_parcels
    begin
      return true if !self[:rcptto]
      self[:rcptto].each do |rcptto|
        # make entries into the database for tracking the deliveries
        parcel = {}
        parcel[:id] = nil
        parcel[:contact_id] = self[:contact_id]
        parcel[:mail_id] = self[:mail_id]
        parcel[:from_url] = self[:mailfrom][:url]
        parcel[:to_url] = rcptto[:url]
        parcel[:delivery_msg] = rcptto[:message]
        parcel[:retry_at] = nil
        if self[:accepted] && rcptto[:accepted]
          parcel[:delivery] = rcptto[:delivery].to_s
        else
          parcel[:delivery] = 'none'
          parcel[:delivery_at] = Time.now
        end
        parcel[:created_at] = parcel[:updated_at] = Time.now.strftime("%Y-%m-%d %H:%M:%S")
        rcptto[:parcel_id] = S3DB[:parcels].insert(parcel)
      end
      return true
    rescue => e
      LOG.error(self[:mail_id]) {e.inspect}
      e.backtrace.each { |line| LOG.error(self[:mail_id]) {line} }
      return false
    end
  end

  def update_parcels(parcels)
    parcels.each { |parcel| S3DB[:parcels].where(:id=>parcel[:id]).update(parcel) }
  end

  def save_mail_into_queue_folder
    # split the ItemOfMail into a hash and a text (which may contain any UTF-8)
    hash = self.dup
    text = hash[:data].delete(:text)
    begin
      # save the mail into the Queue folder
      File::open("#{MailQueue}/#{self[:mail_id]}","w") do |f|
        tmp = hash.pretty_inspect
        f.write("#{tmp.lines.count}\n")
        f.write(tmp)
        f.write("\n")
        text_out = text_in = text.join("\n")
        f.write(text_out.utf8)
      end
      self[:saved] = true
    rescue => e
      LOG.error(self[:mail_id]) {e.inspect}
      e.backtrace.each { |line| LOG.error(self[:mail_id]) {line} }
      return false
    end
  end

  def self::retrieve_mail_from_queue_folder(mail_id)
    m = mail_id.match(/^[0-9A-Za-z]{6}.[0-9A-Za-z]{6}.[0-9A-Za-z]{2}$/)
    raise ArgumentError.new("*666* #{mail_id.inspect} is invalid") if m.nil?

    item = nil
    begin
      # Make sure the file that matches the parcel record exists
      if !File::exist?("#{MailQueue}/#{mail_id}")
        # file missing: mark the parcels none and date them
        parcels = S3DB[:parcels].where(:mail_id=>mail_id).all
        parcels.each do |parcel|
          S3DB[:parcels].where(:id=>parcel[:id]).update(:delivery=>'none', :delivery_at=>Time.now)
        end
        return nil
      end

      tmp = nil; File::open("#{MailQueue}/#{mail_id}","r") { |f| tmp = f.read }
      if tmp.nil?
        LOG.error(mail_id) {"Failed to read data in 'ItemOfMail::retrieve_mail_from_queue_folder'"}
      end

      data = tmp.split("\n")

      # get the number of lines in the hash, and cut that out first
      n = data[0].to_i
      a = data[1..n]
      b = data[n+1..-1]

      # convert the hash
begin
      mail = eval(a.join("\n"))
rescue => e
  LOG.error(mail_id) {"--> X800X file=>'#{MailQueue}/#{mail_id}'"}
  LOG.error(mail_id) {"--> X800X tmp.size=>#{tmp.size}, tmp.class=>#{tmp.class.name}"}
  LOG.error(mail_id) {"--> X800X data.size=>#{data.size}, data.class=>#{data.class.name}"}
  LOG.error(mail_id) {"--> X800X e=>#{e.inspect}"}
  LOG.error(mail_id) {"--> X800X a=>#{a.inspect}"}
  return nil
end

      # create the ItemOfMail structure and insert the text
      item = ItemOfMail::new(mail)
      item[:data][:text] = b
    rescue => e
      LOG.error(mail_id) {e.inspect}
      e.backtrace.each { |line| LOG.error(mail_id) {line} }
    end
    return item
  end

end
