class Contact < Hash

  def initialize(remote_ip)
    # Reset timed-out records
    S3DB[:contacts].where(Sequel.lit("expires_at<'#{Time.now.strftime("%Y-%m-%d %H:%M")}'")).update(:violations=>0)

    # See if it's already there
    rs = S3DB[:contacts].where(:remote_ip=>remote_ip).first
    if rs.nil?
      # No, add one
      self[:id] = nil
      self[:remote_ip] = remote_ip
      self[:hits] = self[:locks] = self[:violations] = 0
      self[:created_at] = Time.now
      id = S3DB[:contacts].insert(self)
      self[:id] = id
    else
      # Yes, copy the data
      rs.each { |k,v| self[k] = v }
    end
    # Set up the data-set for use later
    @ds = S3DB[:contacts].select(:id, :remote_ip, :hits, :locks, :violations, :expires_at, :created_at, :updated_at).where(:id=>self[:id])

    # count the hit and set the flag to count only one violation per invocation
    self[:hits] += 1
    @inhibit = false
    modify
  end

  def remove
    # Remove is rarely used, if at all, because the contacts
    # table keeps a history of IPs that have connected
    if !self[:id].nil?
      @ds.delete
      self[:id] = nil
    end
    nil
  end

  def modify
    # Modify resets the 'expires_at' value after any change to
    # then record, but it's only significant when 'violations'
    # is at or above ProhibitedSeconds
    expires_at = Time.now + ProhibitedSeconds
    if !self[:id].nil?
      self[:expires_at] = expires_at
      self[:updated_at] = Time.now
      @ds.update(self)
    end
    expires_at
  end

  def violation
    # Count the violation and reset the 'expires_at' time -- Also
    # counts the times this IP has been locked out -- only count
    # one violation and one lock per instantiation
    if !inhibited?
      self[:violations]+=1
      @inhibit = true
      if prohibited?
        self[:locks] += 1
        self[:expires_at] = Time.now + ProhibitedSeconds
      end
      modify
    end
  end

  def inhibited?
    @inhibit
  end

  def violations?
    # Returns the current count
    self[:violations]
  end

  def warning?
    # Returns true or false
    self[:violations] >= MaxFailedMsgsPerPeriod
  end

  def prohibited?
    # Returns true or false
    self[:violations] > MaxFailedMsgsPerPeriod
  end

  # set this one to prohibited
  def prohibit
    self[:violations] = MaxFailedMsgsPerPeriod+1
    modify
  end

  def allow
    self[:violations] = 0
    modify
    nil
  end

end

