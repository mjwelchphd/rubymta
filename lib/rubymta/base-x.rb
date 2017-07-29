class String

  # this is used to convert numbers in the email IDs back to base 10
  def from_b(base=62)
    n = 0
    self.each_char do |ch|
      n = n*base
      m = ch.ord
      case
      when m>=97
        k = m-61
      when m>=65
        k = m-55
      when m>=48
        k = m-48
      end
      n += k
    end
    return n
  end

end

class Fixnum

  # this is used to convert a number into segments of
  # base 62 (or 36) for use in creating email IDs
  def to_b(base=62)
    n = self
    r = ""
    while n > 0
      m = n%base
      n /= base
      case
      when m>=36
        k = m+61
      when m>=10
        k = m+55
      when m>=0
        k = m+48
      end
      r << k.chr
    end
    return r.reverse
  end

end
