# frozen_string_literal: true
# shareable_constant_value: literal
# warn_indent: true

module Farce
  class Walker
    # @api private
    # Ignore the man behind the curtain!
    #
    # This is a helper class for lazy-modification that is also cycle-aware.
    class Modification < Walker
      public_class_method :new

      # Bound callback replay rounds for cycles that do not converge, regardless of graph depth.
      MAX_CYCLE_REPLAYS = 32

      # Track an object's replacements, pending writes, and cycle discovery state.
      Node = Struct.new(:original, :result, :destination, :index, :low, :active,
        :plans, :changed, :cyclic, :freeze_result, :finalizer, :skipped, :callback)

      # Record child references and the writer that installs their resolved values.
      Plan = Struct.new(:children, :results, :writer, :hash_keys, :dirty, :applied, :target, :key_stride)
      private_constant :Node, :Plan, :MAX_CYCLE_REPLAYS

      # Keep identity and cycle tracking state local to this walk.
      def initialize(...)
        super
        @nodes     = {}.compare_by_identity
        @stack     = []
        @sequence  = 0
        @node      = nil
        @replaying = false
      end

      # Reuse known results and settle each connected cycle once all its nodes are visited.
      def visit(object, &callback)
        parent          = @node
        previous_object = @current_object
        if node = @nodes[object]
          if node.active && parent
            parent.low    = node.index if parent.low > node.index
            parent.cyclic = node.cyclic = true
          end
          return node.result
        end
        return @seen[object] if @seen.key?(object)

        return super unless Internal.garbage_collectable?(object)

        index          = @sequence
        @sequence     += 1
        node           = Node.new(object, object, object, index, index, true)
        node.callback  = callback
        @nodes[object] = node

        @stack << node

        @node           = node
        @current_object = object
        node.result     = catch(SKIP) { (node.callback || @callback).call(object, self) }
        node.changed  ||= !node.result.equal?(object)

        if node.low == node.index && !node.cyclic
          @stack.pop
          finish(node)
          node.active = false
          node.plans = nil
        elsif node.low == node.index
          start = @stack.index { it.equal?(node) }
          component = @stack.slice!(start..)
          settle(component)
          component.each { it.active = false }
        end

        if parent && node.active
          parent.low    = node.low if parent.low > node.low
          parent.cyclic = true
        end

        node.result
      ensure
        @node = parent
        @current_object = previous_object
      end

      # Traverse alternate targets normally and reuse prepared destinations during replay.
      def traverse(object = current_object)
        return visit(object) { |value| super(value) } if
          @node && Internal.garbage_collectable?(object) && !object.equal?(@node.original) &&
            !object.equal?(@node.destination)
        return @node.destination if @replaying && object.equal?(@node.original)
        super
      end

      # Record child changes and defer writes until cyclic references can be resolved.
      def update(object, values, hash_keys: false, key_stride: 1, &writer)
        if hash_keys && !(Integer === key_stride && key_stride.positive?)
          raise ArgumentError, "key_stride must be a positive Integer"
        end

        node = @node
        unless object.equal?(node.original) || object.equal?(node.destination)
          raise ArgumentError, "update requires the current traversal target"
        end

        results = values
        dirty   = false

        values.each_with_index do |value, index|
          result         = visit(value)
          child          = @nodes[value]
          node.changed ||= child&.changed
          dirty        ||= hash_keys && (index % key_stride).zero? && child && child.changed

          next if value.equal?(result)

          dirty          = true
          results        = values.dup if results.equal?(values)
          results[index] = result
        end

        node.changed ||= dirty
        plan           = Plan.new(values, results, writer, hash_keys, dirty, nil, nil, key_stride)
        (node.plans  ||= []) << plan

        unless node.cyclic
          prepare(node) if plan.dirty
          apply(node, plan) if plan.dirty
        end
        node.destination
      end

      # Record Data members so changed values can initialize a replacement.
      def rebuild_data(object)
        members = object.class.members
        values  = members.map { object.__send__(it) }
        update(object, values) do |target, results|
          target.__send__(:initialize, **members.zip(results).to_h)
          target
        end
      end

      # Freeze the settled result. With copy enabled, preserve the input's state.
      # Call this instead of freezing a preliminary result inside the callback.
      def freeze_result
        return send_to(current_object, :freeze) unless @node && @node.original.equal?(current_object)
        @node.changed       = true unless send_to(@node.original, :frozen?)
        @node.freeze_result = true
        prepare(@node) if @modify != true && !send_to(@node.destination, :frozen?)
        @node.destination
      end

      # Run once after traversal and cycle resolution. The block receives the
      # result and whether it belongs to a cycle. Cyclic finalizers must retain
      # identity. Acyclic finalizers may return a canonical replacement.
      def finalize(&block)
        raise LocalJumpError, "no block given" unless block
        return block.call(current_object, false) unless @node && @node.original.equal?(current_object)
        @node.finalizer = block
        @node.destination
      end

      # Exclude the current node from callback replay, freezing, and finalization.
      def skip(object = current_object)
        @node.skipped = true if @node && @node.original.equal?(current_object)
        super
      end

      # Report whether the object or its visited descendants have changed.
      def changed?(object = current_object)
        node = @nodes[object]
        node ? node.changed == true : (@seen.key?(object) && !@seen[object].equal?(object))
      end

      # Follow pending references to check that hashing cannot reach unfinished Data.
      def hashable?(object)
        return true unless @unfinished_data && !@unfinished_data.empty?
        !Walker.visit(object, constants:, class_variables:) do |value, traversal|
          traversal.return(true) if @unfinished_data.key?(value)
          node = @nodes[value] || @destinations&.[](value)
          if node && node.plans
            traversal.return(true) if @unfinished_data.key?(node.destination)
            node.plans.each { |plan| plan.children.each { traversal.visit(resolved(it)) } }
          else
            traversal.traverse
          end
          false
        end
      end

      # Reject keys and set elements whose Data dependencies are still being built.
      def check_hash_key(object)
        return object if hashable?(object)
        raise ArgumentError, "hash key or set element refers to an unfinished Data value"
      end

      private

      # Look up the latest result for a recorded child reference.
      def resolved(object)
        node = @nodes[object]
        node ? node.result : @seen.fetch(object, object)
      end

      # Refresh a pending write from current child results, including changed hash keys.
      def refresh(node, plan)
        dirty = false
        plan.children.each_with_index do |value, index|
          result = resolved(value)
          unless plan.results[index].equal?(result)
            plan.results = plan.children.dup if plan.results.equal?(plan.children)
            plan.results[index] = result
          end
          child          = @nodes[value]
          node.changed ||= child&.changed
          dirty        ||= !value.equal?(result)
          dirty        ||= plan.hash_keys && (index % plan.key_stride).zero? && child && child.changed
        end
        node.changed ||= dirty
        plan.dirty = dirty
      end

      # Choose a writable destination, copying lazily or allocating unfinished Data.
      def prepare(node, rebuild: false)
        previous = node.destination
        return previous unless rebuild || previous.equal?(node.original)
        object = node.original
        return object if Internal::Noncopyable === object || Abstract::LeaseMap === object
        destination =
          if Data === object
            value = object.class.allocate
            (@unfinished_data ||= {}.compare_by_identity)[value] = true
            value
          elsif @modify == true
            send_to(object, :frozen?) ? send_to(object, :clone, freeze: false) : object
          elsif @modify == :clone
            send_to(object, :clone, freeze: false)
          else
            send_to(object, @modify)
          end
        (@destinations ||= {}.compare_by_identity)[destination] = node unless destination.equal?(object)
        node.destination = destination
        node.result = destination if !node.skipped && (node.result.equal?(object) || node.result.equal?(previous))
        destination
      end

      # Install resolved children and remember cyclic writes to avoid repeating them.
      def apply(node, plan)
        return if plan.target.equal?(node.destination) && plan.applied &&
          plan.results.each_with_index.all? { |value, index| value.equal?(plan.applied[index]) }
        if plan.children.equal?(node.destination)
          children      = plan.children.dup
          plan.results  = children if plan.results.equal?(plan.children)
          plan.children = children
        end
        result = plan.writer.call(node.destination, plan.results)
        if result && !result.equal?(node.destination)
          old = node.destination
          node.destination = result
          node.result = result if node.result.equal?(old)
        end
        @unfinished_data&.delete(node.destination) if Data === node.destination
        return unless node.cyclic
        plan.target = node.destination
        plan.applied = plan.results.dup
      end

      # Resolve a component and freeze all its results before running finalizers.
      def settle(component)
        settle_cycle(component) if component.size > 1 || component.first.cyclic
        component.each { finish(it, finalize: false) }
        component.each { finalize_node(it) } # rubocop:disable Style/CombinableLoops
      end

      # Apply the requested freezing policy and optionally finalize the result.
      def finish(node, finalize: true)
        return if node.skipped
        @node           = node
        @current_object = node.original
        freeze          = node.freeze_result || @freeze == true || (@freeze.nil? && send_to(node.original, :frozen?))
        if freeze
          node.changed = true unless send_to(node.result, :frozen?)
          prepare(node) if @modify != true && node.result.equal?(node.original) && !send_to(node.result, :frozen?)
          send_to(node.result, :freeze)
        end
        finalize_node(node) if finalize
      end

      # Accept a final replacement while preserving the identity of cyclic results.
      def finalize_node(node)
        return if node.skipped || !node.finalizer
        @node           = node
        @current_object = node.original
        result          = node.finalizer.call(node.result, node.cyclic == true)
        raise ArgumentError, "a cyclic finalizer must preserve identity" if node.cyclic && !result.equal?(node.result)
        node.changed ||= !result.equal?(node.result)
        node.result = result
      end

      # Propagate replacements and replay callbacks until result identities stabilize.
      def settle_cycle(component)
        # Allocate destinations to a fixed point before wiring back references.
        MAX_CYCLE_REPLAYS.times do
          loop do
            destinations = component.map(&:destination)
            component.each do |node|
              node.plans&.each { refresh(node, it) }
              freezing = !node.skipped && (node.freeze_result || @freeze == true)
              needed   = node.plans&.any?(&:dirty) || (freezing && @modify != true && !send_to(node.original, :frozen?))
              prepare(node) if needed
              next unless Data === node.destination && send_to(node.destination, :frozen?) && node.plans&.any? do |plan|
                plan.applied && plan.results.each_with_index.any? { |value, index| !value.equal?(plan.applied[index]) }
              end
              prepare(node, rebuild: true)
            end
            break if component.each_with_index.all? { |node, index| node.destination.equal?(destinations[index]) }
          end

          component.sort_by { Data === it.destination ? 2 : (it.plans&.any?(&:hash_keys) ? 1 : 0) }.each do |node|
            @node           = node
            @current_object = node.original
            node.plans&.each do |plan|
              refresh(node, plan)
              apply(node, plan) if plan.dirty
            end
          end

          previous = component.map(&:result)
          component.each do |node|
            next if node.skipped
            @node           = node
            @current_object = node.original
            @replaying      = true
            node.result     = catch(SKIP) { (node.callback || @callback).call(node.original, self) }
            node.changed  ||= !node.result.equal?(node.original)
          ensure
            @replaying = false
          end

          next unless component.each_with_index.all? { |node, index| node.result.equal?(previous[index]) }
          component.each do |node|
            next unless node.plans&.any?(&:dirty)
            target = node.destination
            target.rehash if Hash === target && !target.compare_by_identity?
            target.reset if ::Set === target && !target.compare_by_identity?
          end
          return
        end

        raise ArgumentError, "cyclic modification did not converge"
      end
    end
    private_constant :Modification
  end
end
