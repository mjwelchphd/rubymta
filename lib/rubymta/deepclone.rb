class Object
  # deepclone not only clones the target object, but all
  # objects inside of it, i.e., if you clone a hash of
  # other objects, those other objects will also be cloned.
  def deepclone
    case
    when self.class==Hash
      hash = {}
      self.each { |k,v| hash[k] = v.deepclone }
      hash
    when self.class==Array
      array = []
      self.each { |v| array << v.deepclone }
      array
    else
      if defined?(self.class.new)
        self.class.new(self)
      else
        self
      end
    end
  end
end
