module FatJam
  module ActsAsRevisable
    module Revisable
      def self.included(base)
        base.send(:extend, ClassMethods)
        
        base.class_inheritable_hash :aa_revisable_current_revisions
        base.aa_revisable_current_revisions = {}
        
        class << base
          alias_method_chain :find, :revisable
          alias_method_chain :with_scope, :revisable
        end
      
        base.instance_eval do
          define_callbacks :before_revise, :after_revise, :before_revert, :after_revert, :before_changeset, :after_changeset, :after_branch_created
        
          alias_method_chain :save, :revisable
          alias_method_chain :save!, :revisable
        
          acts_as_scoped_model :find => {:conditions => {:revisable_is_current => true}}
        
          has_many :revisions, :class_name => revision_class_name, :foreign_key => :revisable_original_id, :order => "revisable_number DESC", :dependent => :destroy
          has_many revision_class_name.pluralize.downcase.to_sym, :class_name => revision_class_name, :foreign_key => :revisable_original_id, :order => "revisable_number DESC", :dependent => :destroy
          
          before_create :before_revisable_create
          before_update :before_revisable_update
          after_update :after_revisable_update
        end
      end
      
      def find_revision(number)
        revisions.find_by_revisable_number(number)
      end
      
      def revert_to(*args, &block)
        unless run_callbacks(:before_revert) { |r, o| r == false}
          raise ActiveRecord::RecordNotSaved
        end
      
        options = args.extract_options!
    
        rev = case args.first
        when self.class.revision_class
          args.first
        when :first
          revisions.last
        when :previous
          revisions.first
        when Fixnum
          revisions.find_by_revisable_number(args.first)
        when Time
          revisions.find(:first, :conditions => ["? >= ? and ? <= ?", :revisable_revised_at, args.first, :revisable_current_at, args.first])
        end
    
        unless rev.run_callbacks(:before_restore) { |r, o| r == false}
          raise ActiveRecord::RecordNotSaved
        end
    
        self.class.column_names.each do |col|
          next unless self.class.revisable_should_clone_column? col
          self[col] = rev[col]
        end
    
        @aa_revisable_no_revision = true if options.delete :without_revision
        @aa_revisable_new_params = options
        
        yield(self) if block_given?
        rev.run_callbacks(:after_restore)
        run_callbacks(:after_revert)
        self
      end
    
      def revert_to!(*args)
        revert_to(*args) do
          @aa_revisable_no_revision ? save! : revise!
        end
      end
      
      def revert_to_without_revision(*args)
        options = args.extract_options!
        options.update({:without_revision => true})
        revert_to(*(args << options))
      end
      
      def revert_to_without_revision!(*args)
        options = args.extract_options!
        options.update({:without_revision => true})
        revert_to!(*(args << options))
      end
        
      def revise!
        return if in_revision?
        
        begin
          @aa_revisable_force_revision = true
          in_revision!
          save!
        ensure
          in_revision!(false)
          @aa_revisable_force_revision = false
        end
      end
      
      def revised?
        @aa_revisable_was_revised || false
      end
      
      # Groups statements that could trigger several revisions into
      # a single revision. The revision is created once #save is called.
      # 
      #   @project.revision_number # => 1
      #   @project.changeset do |project|
      #     # each one of the following statements would 
      #     # normally trigger a revision
      #     project.update_attribute(:name, "new name")
      #     project.revise!
      #     project.revise!
      #   end
      #   @project.save
      #   @project.revision_number # => 2
      def changeset(&block)
        return unless block_given?
        
        return yield(self) if in_revision?
        
        unless run_callbacks(:before_changeset) { |r, o| r == false}
          raise ActiveRecord::RecordNotSaved
        end
        
        begin
          @aa_revisable_force_revision = true
          in_revision!
        
          returning(yield(self)) do
            run_callbacks(:after_changeset)
          end
        ensure
          in_revision!(false)       
        end
      end
      
      # Same as +changeset+ except it also saves
      def changeset!(&block)
        returning(changeset(&block)) do
          save!
        end
      end
      
      def revision_number
        revisions.first.revisable_number
      rescue NoMethodError
        0
      end
      
      def save_with_revisable!(*args)
        @aa_revisable_new_params ||= args.extract_options!
        @aa_revisable_no_revision = true if @aa_revisable_new_params.delete :without_revision
        save_without_revisable!(*args)
      end
    
      def save_with_revisable(*args)
        @aa_revisable_new_params ||= args.extract_options!
        @aa_revisable_no_revision = true if @aa_revisable_new_params.delete :without_revision
        save_without_revisable(*args)
      end
      
      def before_revisable_create
        self[:revisable_is_current] = true
      end
    
      def should_revise?
        return true if @aa_revisable_force_revision == true
        return false if @aa_revisable_no_revision == true
        return false unless self.changed?
        !(self.changed.map(&:downcase) & self.class.revisable_columns).blank?
      end
    
      def before_revisable_update
        return unless should_revise?
        return false unless run_callbacks(:before_revise) { |r, o| r == false}
    
        @revisable_revision = self.to_revision
      end
  
      def after_revisable_update
        if @revisable_revision
          @revisable_revision.save
          @aa_revisable_was_revised = true
          revisions.reload
          run_callbacks(:after_revise)
        end
        @aa_revisable_force_revision = false
      end
    
      def in_revision?
        key = self.read_attribute(self.class.primary_key)
        aa_revisable_current_revisions[key] || false
      end

      def in_revision!(val=true)
        key = self.read_attribute(self.class.primary_key)
        aa_revisable_current_revisions[key] = val
        aa_revisable_current_revisions.delete(key) unless val
      end
      
      def to_revision
        rev = self.class.revision_class.new(@aa_revisable_new_params)

        rev.revisable_original_id = self.id

        self.class.column_names.each do |col|
          next unless self.class.revisable_should_clone_column? col
          val = self.send("#{col}_changed?") ? self.send("#{col}_was") : self.send(col)
          rev.send("#{col}=", val)
        end

        @aa_revisable_new_params = nil

        rev
      end
      
      module ClassMethods      
        def with_scope_with_revisable(*args, &block)
          options = (args.grep(Hash).first || {})[:find]

          if options && options.delete(:with_revisions)
            without_model_scope do
              with_scope_without_revisable(*args, &block)
            end
          else
            with_scope_without_revisable(*args, &block)
          end
        end
      
        def find_with_revisable(*args)
          options = args.grep(Hash).first
        
          if options && options.delete(:with_revisions)
            without_model_scope do
              find_without_revisable(*args)
            end
          else
            find_without_revisable(*args)
          end
        end
      
        def find_with_revisions(*args)
          args << {} if args.grep(Hash).blank?
          args.grep(Hash).first.update({:with_revisions => true})
          find_with_revisable(*args)
        end
      
        def revision_class_name
          self.revisable_options.revision_class_name || "#{self.class_name}Revision"
        end
      
        def revision_class
          @aa_revision_class ||= revision_class_name.constantize
        end
        
        def revisable_class
          self
        end
        
        def revisable_columns
          return @aa_revisable_columns unless @aa_revisable_columns.blank?
          return @aa_revisable_columns ||= [] if self.revisable_options.except == :all
          return @aa_revisable_columns ||= [self.revisable_options.only].flatten.map(&:to_s).map(&:downcase) unless self.revisable_options.only.blank?
                    
          except = [self.revisable_options.except].flatten || []
          except += REVISABLE_SYSTEM_COLUMNS
          except += REVISABLE_UNREVISABLE_COLUMNS
          except.uniq!

          @aa_revisable_columns ||= (column_names - except.map(&:to_s)).flatten.map(&:downcase)
        end
      end
    end
  end
end