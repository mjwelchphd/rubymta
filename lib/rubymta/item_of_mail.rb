require_relative 'base-x'
require_relative 'deepclone'
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
        self[:data][:headers][keyword.downcase.gsub("-","_").to_sym] = value.strip
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
      LOG.error(self[:mail_id]) {e.to_s}
      e.backtrace.each { |line| LOG.error(self[:mail_id]) {line} }
      return false
    end
  end

  def update_parcels(parcels)
    parcels.each { |parcel| S3DB[:parcels].where(:id=>parcel[:id]).update(parcel) }
  end

  def save_mail_into_queue_folder
    begin
      # save the mail in the Queue folder
      File::open("#{MailQueue}/#{self[:mail_id]}","w") do |f|
        self[:saved] = true
        f.write(self.pretty_inspect)
      end
      return true
    rescue => e
      LOG.error(self[:mail_id]) {e.to_s}
      e.backtrace.each { |line| LOG.error(self[:mail_id]) {line} }
      return false
    end
  end

  def self::retrieve_mail_from_queue_folder(mail_id)
    item = nil
    begin
      mail = nil
      File::open("#{MailQueue}/#{mail_id}","r") do |f|
        mail = eval(f.read)
        item = ItemOfMail::new(mail)
      end
    rescue => e
      LOG.error(self[:mail_id]) {e.to_s}
      e.backtrace.each { |line| LOG.error(self[:mail_id]) {line} }
    end
    return item
  end

end
