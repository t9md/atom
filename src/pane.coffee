Grim = require 'grim'
{find, compact, extend, last, first, remove, isFunction} = require 'underscore-plus'
{CompositeDisposable, Emitter} = require 'event-kit'
Model = require './model'
PaneAxis = require './pane-axis'

getItemURI = (item) ->
  if typeof item?.getURI is 'function'
    item.getURI()
  else if typeof item?.getUri is 'function'
    item.getUri()

isPane = (obj) ->
  obj instanceof Pane

# Extended: A container for presenting content in the center of the workspace.
# Panes can contain multiple items, one of which is *active* at a given time.
# The view corresponding to the active item is displayed in the interface. In
# the default configuration, tabs are also displayed for each item.
#
# Each pane may also contain one *pending* item. When a pending item is added
# to a pane, it will replace the currently pending item, if any, instead of
# simply being added. In the default configuration, the text in the tab for
# pending items is shown in italics.
module.exports =
class Pane extends Model
  container: undefined
  activeItem: undefined
  focused: false

  @deserialize: (state, {deserializers, applicationDelegate, config, notifications}) ->
    {items, itemStackIndices, activeItemURI, activeItemUri} = state
    activeItemURI ?= activeItemUri
    state.items = compact(items.map (itemState) -> deserializers.deserialize(itemState))
    state.activeItem = find state.items, (item) ->
      itemURI = item.getURI() if isFunction(item.getURI)
      itemURI is activeItemURI
    options = {
      deserializerManager: deserializers,
      notificationManager: notifications,
      config, applicationDelegate
    }
    new Pane(extend(state, options))

  constructor: (params) ->
    super

    {
      @activeItem, @focused, @applicationDelegate, @notificationManager, @config,
      @deserializerManager
    } = params

    @emitter = new Emitter
    @subscriptionsPerItem = new WeakMap
    @items = []
    @itemStack = []

    @addItems(compact(params?.items ? []))
    @setActiveItem(@items[0]) unless @getActiveItem()?
    @addItemsToStack(params?.itemStackIndices ? [])
    @setFlexScale(params?.flexScale ? 1)

  serialize: ->
    if isFunction(@activeItem?.getURI)
      activeItemURI = @activeItem.getURI()
    itemsToBeSerialized = compact(@items.map((item) -> item if typeof item.serialize is 'function'))
    itemStackIndices = (itemsToBeSerialized.indexOf(item) for item in @itemStack when typeof item.serialize is 'function')

    {
      deserializer: 'Pane'
      @id,
      items: itemsToBeSerialized.map((item) -> item.serialize())
      itemStackIndices: itemStackIndices
      activeItemURI,
      @focused,
      @flexScale,
    }

  getParent: -> @parent

  setParent: (@parent) -> @parent

  getContainer: -> @container

  setContainer: (container) ->
    if container and container isnt @container
      @container = container
      container.didAddPane({pane: this})

  setFlexScale: (@flexScale) ->
    @emitter.emit 'did-change-flex-scale', @flexScale
    @flexScale

  getFlexScale: -> @flexScale

  increaseSize: -> @setFlexScale(@getFlexScale() * 1.1)

  decreaseSize: -> @setFlexScale(@getFlexScale() / 1.1)

  ###
  Section: Event Subscription
  ###

  # Public: Invoke the given callback when the pane resizes
  #
  # The callback will be invoked when pane's flexScale property changes.
  # Use {::getFlexScale} to get the current value.
  #
  # * `callback` {Function} to be called when the pane is resized
  #   * `flexScale` {Number} representing the panes `flex-grow`; ability for a
  #     flex item to grow if necessary.
  #
  # Returns a {Disposable} on which '.dispose()' can be called to unsubscribe.
  onDidChangeFlexScale: (callback) ->
    @emitter.on 'did-change-flex-scale', callback

  # Public: Invoke the given callback with the current and future values of
  # {::getFlexScale}.
  #
  # * `callback` {Function} to be called with the current and future values of
  #   the {::getFlexScale} property.
  #   * `flexScale` {Number} representing the panes `flex-grow`; ability for a
  #     flex item to grow if necessary.
  #
  # Returns a {Disposable} on which `.dispose()` can be called to unsubscribe.
  observeFlexScale: (callback) ->
    callback(@flexScale)
    @onDidChangeFlexScale(callback)

  # Public: Invoke the given callback when the pane is activated.
  #
  # The given callback will be invoked whenever {::activate} is called on the
  # pane, even if it is already active at the time.
  #
  # * `callback` {Function} to be called when the pane is activated.
  #
  # Returns a {Disposable} on which `.dispose()` can be called to unsubscribe.
  onDidActivate: (callback) ->
    @emitter.on 'did-activate', callback

  # Public: Invoke the given callback before the pane is destroyed.
  #
  # * `callback` {Function} to be called before the pane is destroyed.
  #
  # Returns a {Disposable} on which `.dispose()` can be called to unsubscribe.
  onWillDestroy: (callback) ->
    @emitter.on 'will-destroy', callback

  # Public: Invoke the given callback when the pane is destroyed.
  #
  # * `callback` {Function} to be called when the pane is destroyed.
  #
  # Returns a {Disposable} on which `.dispose()` can be called to unsubscribe.
  onDidDestroy: (callback) ->
    @emitter.on 'did-destroy', callback

  # Public: Invoke the given callback when the value of the {::isActive}
  # property changes.
  #
  # * `callback` {Function} to be called when the value of the {::isActive}
  #   property changes.
  #   * `active` {Boolean} indicating whether the pane is active.
  #
  # Returns a {Disposable} on which `.dispose()` can be called to unsubscribe.
  onDidChangeActive: (callback) ->
    @container.onDidChangeActivePane (activePane) =>
      callback(this is activePane)

  # Public: Invoke the given callback with the current and future values of the
  # {::isActive} property.
  #
  # * `callback` {Function} to be called with the current and future values of
  #   the {::isActive} property.
  #   * `active` {Boolean} indicating whether the pane is active.
  #
  # Returns a {Disposable} on which `.dispose()` can be called to unsubscribe.
  observeActive: (callback) ->
    callback(@isActive())
    @onDidChangeActive(callback)

  # Public: Invoke the given callback when an item is added to the pane.
  #
  # * `callback` {Function} to be called with when items are added.
  #   * `event` {Object} with the following keys:
  #     * `item` The added pane item.
  #     * `index` {Number} indicating where the item is located.
  #
  # Returns a {Disposable} on which `.dispose()` can be called to unsubscribe.
  onDidAddItem: (callback) ->
    @emitter.on 'did-add-item', callback

  # Public: Invoke the given callback when an item is removed from the pane.
  #
  # * `callback` {Function} to be called with when items are removed.
  #   * `event` {Object} with the following keys:
  #     * `item` The removed pane item.
  #     * `index` {Number} indicating where the item was located.
  #
  # Returns a {Disposable} on which `.dispose()` can be called to unsubscribe.
  onDidRemoveItem: (callback) ->
    @emitter.on 'did-remove-item', callback

  # Public: Invoke the given callback before an item is removed from the pane.
  #
  # * `callback` {Function} to be called with when items are removed.
  #   * `event` {Object} with the following keys:
  #     * `item` The pane item to be removed.
  #     * `index` {Number} indicating where the item is located.
  onWillRemoveItem: (callback) ->
    @emitter.on 'will-remove-item', callback

  # Public: Invoke the given callback when an item is moved within the pane.
  #
  # * `callback` {Function} to be called with when items are moved.
  #   * `event` {Object} with the following keys:
  #     * `item` The removed pane item.
  #     * `oldIndex` {Number} indicating where the item was located.
  #     * `newIndex` {Number} indicating where the item is now located.
  #
  # Returns a {Disposable} on which `.dispose()` can be called to unsubscribe.
  onDidMoveItem: (callback) ->
    @emitter.on 'did-move-item', callback

  # Public: Invoke the given callback with all current and future items.
  #
  # * `callback` {Function} to be called with current and future items.
  #   * `item` An item that is present in {::getItems} at the time of
  #     subscription or that is added at some later time.
  #
  # Returns a {Disposable} on which `.dispose()` can be called to unsubscribe.
  observeItems: (callback) ->
    callback(item) for item in @getItems()
    @onDidAddItem ({item}) -> callback(item)

  # Public: Invoke the given callback when the value of {::getActiveItem}
  # changes.
  #
  # * `callback` {Function} to be called with when the active item changes.
  #   * `activeItem` The current active item.
  #
  # Returns a {Disposable} on which `.dispose()` can be called to unsubscribe.
  onDidChangeActiveItem: (callback) ->
    @emitter.on 'did-change-active-item', callback

  # Public: Invoke the given callback with the current and future values of
  # {::getActiveItem}.
  #
  # * `callback` {Function} to be called with the current and future active
  #   items.
  #   * `activeItem` The current active item.
  #
  # Returns a {Disposable} on which `.dispose()` can be called to unsubscribe.
  observeActiveItem: (callback) ->
    callback(@getActiveItem())
    @onDidChangeActiveItem(callback)

  # Public: Invoke the given callback before items are destroyed.
  #
  # * `callback` {Function} to be called before items are destroyed.
  #   * `event` {Object} with the following keys:
  #     * `item` The item that will be destroyed.
  #     * `index` The location of the item.
  #
  # Returns a {Disposable} on which `.dispose()` can be called to
  # unsubscribe.
  onWillDestroyItem: (callback) ->
    @emitter.on 'will-destroy-item', callback

  # Called by the view layer to indicate that the pane has gained focus.
  focus: ->
    @focused = true
    @activate() unless @isActive()

  # Called by the view layer to indicate that the pane has lost focus.
  blur: ->
    @focused = false
    true # if this is called from an event handler, don't cancel it

  isFocused: -> @focused

  getPanes: -> [this]

  unsubscribeFromItem: (item) ->
    @subscriptionsPerItem.get(item)?.dispose()
    @subscriptionsPerItem.delete(item)

  ###
  Section: Items
  ###

  # Public: Get the items in this pane.
  #
  # Returns an {Array} of items.
  getItems: ->
    @items.slice()

  # Public: Get the active pane item in this pane.
  #
  # Returns a pane item.
  getActiveItem: -> @activeItem

  setActiveItem: (activeItem, options) ->
    {modifyStack} = options if options?
    unless activeItem is @activeItem
      @addItemToStack(activeItem) unless modifyStack is false
      @activeItem = activeItem
      @emitter.emit 'did-change-active-item', @activeItem
    @activeItem

  # Build the itemStack after deserializing
  addItemsToStack: (itemStackIndices) ->
    return if @items.length is 0
    length = itemStackIndices.length

    if length is 0 or length isnt @items.length or itemStackIndices.indexOf(-1) >= 0
      itemStackIndices = (i for i in [0..@items.length-1])
    for itemIndex in itemStackIndices
      @addItemToStack(@items[itemIndex])
    return

  # Add item (or move item) to the end of the itemStack
  addItemToStack: (newItem) ->
    return unless newItem?
    @removeItemFromStack(newItem)
    @itemStack.push(newItem)

  # Return an {TextEditor} if the pane item is an {TextEditor}, or null otherwise.
  getActiveEditor: ->
    @activeItem if atom.workspace.isTextEditor(@activeItem)

  # Public: Return the item at the given index.
  #
  # * `index` {Number}
  #
  # Returns an item or `null` if no item exists at the given index.
  itemAtIndex: (index) ->
    @items[index]

  # Makes the next item in the itemStack active.
  activateNextRecentlyUsedItem: ->
    return if @isEmpty()
    @itemStackIndex = @itemStack.length - 1 unless @itemStackIndex?
    @itemStackIndex = @itemStack.length if @itemStackIndex is 0
    @itemStackIndex = @itemStackIndex - 1
    nextRecentlyUsedItem = @itemStack[@itemStackIndex]
    @setActiveItem(nextRecentlyUsedItem, modifyStack: false)

  # Makes the previous item in the itemStack active.
  activatePreviousRecentlyUsedItem: ->
    return if @isEmpty()
    if @itemStackIndex + 1 is @itemStack.length or not @itemStackIndex?
      @itemStackIndex = -1
    @itemStackIndex = @itemStackIndex + 1
    previousRecentlyUsedItem = @itemStack[@itemStackIndex]
    @setActiveItem(previousRecentlyUsedItem, modifyStack: false)

  # Moves the active item to the end of the itemStack once the ctrl key is lifted
  moveActiveItemToTopOfStack: ->
    delete @itemStackIndex
    @addItemToStack(@activeItem)

  getLastItemIndex: ->
    @items.length - 1

  isEmpty: ->
    @items.length is 0

  hasItem: (item) ->
    item in @items

  # Public: Makes the next item active.
  activateNextItem: ->
    return if @isEmpty()
    index = @getActiveItemIndex() + 1
    @activateItemAtIndex(@getValidIndex(index))

  # Public: Makes the previous item active.
  activatePreviousItem: ->
    return if @isEmpty()
    index = @getActiveItemIndex() - 1
    @activateItemAtIndex(@getValidIndex(index))

  activateLastItem: ->
    @activateItemAtIndex(@getLastItemIndex())

  isValidItemIndex: (index) ->
    index in [0..@getLastItemIndex()]

  getValidIndex: (index) ->
    lastItemIndex = @getLastItemIndex()
    if index < 0
      lastItemIndex
    else if index > lastItemIndex
      0
    else
      index

  # Public: Move the active tab to the right.
  moveItemRight: ->
    index = @getActiveItemIndex() + 1
    @moveItem(@getActiveItem(), index) if @isValidItemIndex(index)

  # Public: Move the active tab to the left
  moveItemLeft: ->
    index = @getActiveItemIndex() - 1
    @moveItem(@getActiveItem(), index) if @isValidItemIndex(index)

  # Public: Get the index of the active item.
  #
  # Returns a {Number}.
  getActiveItemIndex: ->
    @items.indexOf(@activeItem)

  # Public: Activate the item at the given index.
  #
  # * `index` {Number}
  activateItemAtIndex: (index) ->
    item = @itemAtIndex(index) or @getActiveItem()
    @setActiveItem(item)

  # Public: Make the given item *active*, causing it to be displayed by
  # the pane's view.
  #
  # * `options` (optional) {Object}
  #   * `pending` (optional) {Boolean} indicating that the item should be added
  #     in a pending state if it does not yet exist in the pane. Existing pending
  #     items in a pane are replaced with new pending items when they are opened.
  activateItem: (item, options={}) ->
    return unless item?
    index = @getActiveItemIndex()
    index += 1 unless @isPendingItem(@itemAtIndex[index])
    options.index = index
    @addItem(item, options)
    @setActiveItem(item)

  # Public: Add the given item to the pane.
  #
  # * `item` The item to add. It can be a model with an associated view or a
  #   view.
  # * `options` (optional) {Object}
  #   * `index` (optional) {Number} indicating the index at which to add the item.
  #     If omitted, the item is added after the current active item.
  #   * `pending` (optional) {Boolean} indicating that the item should be
  #     added in a pending state. Existing pending items in a pane are replaced with
  #     new pending items when they are opened.
  #
  # Returns the added item.
  addItem: (item, options={}) ->
    # Backward compat with old API:
    #   addItem(item, index=@getActiveItemIndex() + 1)
    if typeof options is "number"
      Grim.deprecate("Pane::addItem(item, #{options}) is deprecated in favor of Pane::addItem(item, {index: #{options}})")
      options = index: options

    index = options.index ? @getActiveItemIndex() + 1
    moved = options.moved ? false
    pending = options.pending ? false

    throw new Error("Pane items must be objects. Attempted to add item #{item}.") unless item? and typeof item is 'object'
    throw new Error("Adding a pane item with URI '#{item.getURI?()}' that has already been destroyed") if item.isDestroyed?()

    return if item in @items

    if typeof item.onDidDestroy is 'function'
      itemSubscriptions = new CompositeDisposable
      itemSubscriptions.add item.onDidDestroy => @removeItem(item, false)
      if typeof item.onDidTerminatePendingState is "function"
        itemSubscriptions.add item.onDidTerminatePendingState =>
          @clearPendingItem() if @isPendingItem(item)
      @subscriptionsPerItem.set(item, itemSubscriptions)

    @items.splice(index, 0, item)
    lastPendingItem = @getPendingItem()
    replacingPendingItem = lastPendingItem? and not moved
    @pendingItem = null if replacingPendingItem
    @setPendingItem(item) if pending

    @emitter.emit 'did-add-item', {item, index, moved}
    @destroyItem(lastPendingItem) if replacingPendingItem
    @setActiveItem(item) unless @getActiveItem()?
    item

  setPendingItem: (item) =>
    return if @isPendingItem(item)
    previousPendingItem = @pendingItem
    @pendingItem = item
    if previousPendingItem?
      @emitter.emit 'item-did-terminate-pending-state', previousPendingItem

  # [t9md] why need FAT-allow?
  getPendingItem: =>
    @pendingItem or null

  isPendingItem: (item) ->
    item? and @getPendingItem() is item

  # [t9md] why need FAT-allow?
  clearPendingItem: =>
    @setPendingItem(null)

  # [t9md] why need FAT-allow?
  onItemDidTerminatePendingState: (callback) =>
    @emitter.on 'item-did-terminate-pending-state', callback

  # Public: Add the given items to the pane.
  #
  # * `items` An {Array} of items to add. Items can be views or models with
  #   associated views. Any objects that are already present in the pane's
  #   current items will not be added again.
  # * `index` (optional) {Number} index at which to add the items. If omitted,
  #   the item is #   added after the current active item.
  #
  # Returns an {Array} of added items.
  addItems: (items, index=@getActiveItemIndex() + 1) ->
    newItems = items.filter (item) => not @hasItem(item)
    @addItem(item, {index: index + i}) for item, i in newItems
    newItems

  removeItem: (item, moved) ->
    index = @items.indexOf(item)
    return if index is -1

    @clearPendingItem() if @isPendingItem(item)
    @removeItemFromStack(item)
    destroyed = if moved then false else true

    @emitter.emit 'will-remove-item', {item, index, destroyed, moved}
    @unsubscribeFromItem(item)

    if item is @activeItem
      if @items.length is 1
        @setActiveItem(undefined)
      else if index is 0
        @activateNextItem()
      else
        @activatePreviousItem()
    @items.splice(index, 1)
    @emitter.emit 'did-remove-item', {item, index, destroyed, moved}
    @container?.didDestroyPaneItem({item, index, pane: this}) unless moved
    @destroy() if @items.length is 0 and @config.get('core.destroyEmptyPanes')

  # Remove the given item from the itemStack.
  #
  # * `item` The item to remove.
  # * `index` {Number} indicating the index to which to remove the item from the itemStack. <- [t9md] this is lie!
  removeItemFromStack: (item) ->
    remove(@itemStack, item)

  # Public: Move the given item to the given index.
  #
  # * `item` The item to move.
  # * `index` {Number} indicating the index to which to move the item.
  moveItem: (item, newIndex) ->
    oldIndex = @items.indexOf(item)
    @items.splice(oldIndex, 1)
    @items.splice(newIndex, 0, item)
    @emitter.emit 'did-move-item', {item, oldIndex, newIndex}

  # Public: Move the given item to the given index on another pane.
  #
  # * `item` The item to move.
  # * `pane` {Pane} to which to move the item.
  # * `index` {Number} indicating the index to which to move the item in the
  #   given pane.
  moveItemToPane: (item, pane, index) ->
    @removeItem(item, true)
    pane.addItem(item, {index, moved: true})

  # Public: Destroy the active item and activate the next item.
  destroyActiveItem: ->
    @destroyItem(@getActiveItem())
    false

  # Public: Destroy the given item.
  #
  # If the item is active, the next item will be activated. If the item is the
  # last item, the pane will be destroyed if the `core.destroyEmptyPanes` config
  # setting is `true`.
  #
  # * `item` Item to destroy
  destroyItem: (item) ->
    index = @items.indexOf(item)
    return if index is -1

    @emitter.emit 'will-destroy-item', {item, index}
    @container?.willDestroyPaneItem({item, index, pane: this})
    if @promptToSaveItem(item)
      @removeItem(item, false)
      item.destroy?()
      true
    else
      false

  # Public: Destroy all items.
  destroyItems: ->
    @destroyItem(item) for item in @getItems()
    return

  # Public: Destroy all items except for the active item.
  destroyInactiveItems: ->
    @destroyItem(item) for item in @getItems() when item isnt @activeItem
    return

  promptToSaveItem: (item, options={}) ->
    return true unless item.shouldPromptToSave?(options)

    if isFunction(item.getURI)
      uri = item.getURI()
    else if isFunction(item.getUri)
      uri = item.getUri()
    else
      return true

    saveDialog = (saveButtonText, saveFn, message) =>
      chosen = @applicationDelegate.confirm
        message: message
        detailedMessage: "Your changes will be lost if you close this item without saving."
        buttons: [saveButtonText, "Cancel", "Don't save"]
      switch chosen
        when 0 then saveFn(item, saveError)
        when 1 then false
        when 2 then true

    saveError = (error) =>
      if error
        saveDialog("Save as", @saveItemAs, "'#{item.getTitle?() ? uri}' could not be saved.\nError: #{@getMessageForErrorCode(error.code)}")
      else
        true

    saveDialog("Save", @saveItem, "'#{item.getTitle?() ? uri}' has changes, do you want to save them?")

  # Public: Save the active item.
  saveActiveItem: (nextAction) ->
    @saveItem(@getActiveItem(), nextAction)

  # Public: Prompt the user for a location and save the active item with the
  # path they select.
  #
  # * `nextAction` (optional) {Function} which will be called after the item is
  #   successfully saved.
  saveActiveItemAs: (nextAction) ->
    @saveItemAs(@getActiveItem(), nextAction)

  # Public: Save the given item.
  #
  # * `item` The item to save.
  # * `nextAction` (optional) {Function} which will be called with no argument <- [t9md] lie, called with error in case of error
  #   after the item is successfully saved, or with the error if it failed.
  #   The return value will be that of `nextAction` or `undefined` if it was not
  #   provided
  saveItem: (item, nextAction) =>
    itemURI = getItemURI(item)

    if itemURI?
      try
        item.save?()
        nextAction?()
      catch error
        if nextAction
          nextAction(error)
        else
          @handleSaveError(error, item)
    else
      @saveItemAs(item, nextAction)

  # Public: Prompt the user for a location and save the active item with the
  # path they select.
  #
  # * `item` The item to save.
  # * `nextAction` (optional) {Function} which will be called with no argument
  #   after the item is successfully saved, or with the error if it failed.
  #   The return value will be that of `nextAction` or `undefined` if it was not
  #   provided
  saveItemAs: (item, nextAction) =>
    return unless item?.saveAs?

    saveOptions = item.getSaveDialogOptions?() ? {}
    saveOptions.defaultPath ?= item.getPath()
    newItemPath = @applicationDelegate.showSaveDialog(saveOptions)
    if newItemPath
      try
        item.saveAs(newItemPath)
        nextAction?()
      catch error
        if nextAction
          nextAction(error)
        else
          @handleSaveError(error, item)

  # Public: Save all items.
  saveItems: ->
    @saveItem(item) for item in @getItems() when item.isModified?()
    return

  # Public: Return the first item that matches the given URI or undefined if
  # none exists.
  #
  # * `uri` {String} containing a URI.
  itemForURI: (uri) ->
    find @items, (item) -> getItemURI(item) is uri

  # Public: Activate the first item that matches the given URI.
  #
  # * `uri` {String} containing a URI.
  #
  # Returns a {Boolean} indicating whether an item matching the URI was found.
  activateItemForURI: (uri) ->
    if item = @itemForURI(uri)
      @activateItem(item)
      true
    else
      false

  copyActiveItem: ->
    if @activeItem?
      @activeItem.copy?() ? @deserializerManager.deserialize(@activeItem.serialize())

  ###
  Section: Lifecycle
  ###

  # Public: Determine whether the pane is active.
  #
  # Returns a {Boolean}.
  isActive: ->
    @container?.getActivePane() is this

  # Public: Makes this pane the *active* pane, causing it to gain focus.
  activate: ->
    throw new Error("Pane has been destroyed") if @isDestroyed()
    @container?.setActivePane(this)
    @emitter.emit 'did-activate'

  # Public: Close the pane and destroy all its items.
  #
  # If this is the last pane, all the items will be destroyed but the pane
  # itself will not be destroyed.
  destroy: ->
    if @container?.isAlive() and @container.getPanes().length is 1
      @destroyItems()
    else
      @emitter.emit 'will-destroy'
      @container?.willDestroyPane(pane: this)
      super

  # Called by model superclass.
  destroyed: ->
    @container.activateNextPane() if @isActive()
    @emitter.emit 'did-destroy'
    @emitter.dispose()
    item.destroy?() for item in @items.slice()
    @container?.didDestroyPane(pane: this)

  ###
  Section: Splitting
  ###

  # Public: Create a new pane to the left of this pane.
  #
  # * `params` (optional) {Object} with the following keys:
  #   * `items` (optional) {Array} of items to add to the new pane.
  #   * `copyActiveItem` (optional) {Boolean} true will copy the active item into the new split pane
  #
  # Returns the new {Pane}.
  splitLeft: (params) ->
    @split('horizontal', 'before', params)

  # Public: Create a new pane to the right of this pane.
  #
  # * `params` (optional) {Object} with the following keys:
  #   * `items` (optional) {Array} of items to add to the new pane.
  #   * `copyActiveItem` (optional) {Boolean} true will copy the active item into the new split pane
  #
  # Returns the new {Pane}.
  splitRight: (params) ->
    @split('horizontal', 'after', params)

  # Public: Creates a new pane above the receiver.
  #
  # * `params` (optional) {Object} with the following keys:
  #   * `items` (optional) {Array} of items to add to the new pane.
  #   * `copyActiveItem` (optional) {Boolean} true will copy the active item into the new split pane
  #
  # Returns the new {Pane}.
  splitUp: (params) ->
    @split('vertical', 'before', params)

  # Public: Creates a new pane below the receiver.
  #
  # * `params` (optional) {Object} with the following keys:
  #   * `items` (optional) {Array} of items to add to the new pane.
  #   * `copyActiveItem` (optional) {Boolean} true will copy the active item into the new split pane
  #   * `moveActiveItem` (optional) {Boolean} true will move active item into the new split pane
  #
  # Returns the new {Pane}.
  splitDown: (params) ->
    @split('vertical', 'after', params)

  split: (orientation, side, params) ->
    if params?.copyActiveItem
      params.items ?= []
      params.items.push(@copyActiveItem())

    if @parent.orientation isnt orientation
      @parent.replaceChild(this, new PaneAxis({@container, orientation, children: [this], @flexScale}))
      @setFlexScale(1)

    newPane = new Pane(extend({@applicationDelegate, @notificationManager, @deserializerManager, @config}, params))
    switch side
      when 'before' then @parent.insertChildBefore(this, newPane)
      when 'after' then @parent.insertChildAfter(this, newPane)

    @moveItemToPane(@activeItem, newPane) if params?.moveActiveItem

    newPane.activate()
    newPane

  findSubling: (orientation, firstOrLastFn) ->
    if @parent.orientation is orientation and isPane(child = firstOrLastFn(@parent.children))
      child
    else
      this

  # If the parent is a horizontal axis, returns its first child if it is a pane;
  # otherwise returns this pane.
  findLeftmostSibling: -> @findSubling('horizontal', first)

  # If the parent is a horizontal axis, returns its last child if it is a pane;
  # otherwise returns a new pane created by splitting this pane rightward.
  findOrCreateRightmostSibling: ->
    child = @findSubling('horizontal', last)
    if child is this then child else @splitRight()

  # If the parent is a vertical axis, returns its first child if it is a pane;
  # otherwise returns this pane.
  findTopmostSibling: -> @findSubling('vertical', first)

  # If the parent is a vertical axis, returns its last child if it is a pane;
  # otherwise returns a new pane created by splitting this pane bottomward.
  findOrCreateBottommostSibling: ->
    child = @findSubling('vertical', last)
    if child is this then child else @splitDown()

  close: ->
    @destroy() if @confirmClose()

  confirmClose: ->
    for item in @getItems()
      return false unless @promptToSaveItem(item)
    true

  handleSaveError: (error, item) ->
    itemPath = error.path ? item?.getPath?()

    addWarningWithPath = (message, options) =>
      message = "#{message} '#{itemPath}'" if itemPath
      @notificationManager.addWarning(message, options)

    addWarning = @notificationManager.addWarning.bind(@notificationManager)

    customMessage = @getMessageForErrorCode(error.code)
    switch
      when customMessage?
        addWarningWithPath("Unable to save file: #{customMessage}")
      when (error.code is 'EISDIR') or error.message?.endsWith?('is a directory')
        addWarning("Unable to save file: #{error.message}")
      when error.code in ['EPERM', 'EBUSY', 'UNKNOWN', 'EEXIST', 'ELOOP', 'EAGAIN']
        addWarningWithPath('Unable to save file', detail: error.message)
      when errorMatch = /ENOTDIR, not a directory '([^']+)'/.exec(error.message)
        fileName = errorMatch[1]
        addWarning("Unable to save file: A directory in the path '#{fileName}' could not be written to")
      else
        throw error

  errorCodeToMessage =
    EACCES: 'Permission denied'
    ECONNRESET: 'Connection reset'
    EINTR: 'Interrupted system call'
    EIO: 'I/O error writing file'
    ENOSPC: 'No space left on device'
    ENOTSUP: 'Operation not supported on socket'
    ENXIO: 'No such device or address'
    EROFS: 'Read-only file system'
    ESPIPE: 'Invalid seek'
    ETIMEDOUT: 'Connection timed out'
  getMessageForErrorCode: (errorCode) ->
    errorCodeToMessage[errorCode]
