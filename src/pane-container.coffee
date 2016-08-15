{find, flatten} = require 'underscore-plus'
{Emitter, CompositeDisposable} = require 'event-kit'
Gutter = require './gutter'
Model = require './model'
Pane = require './pane'
ItemRegistry = require './item-registry'

isPane = (obj) ->
  obj instanceof Pane

getValidIndexForArray = (index, array) ->
  maxIndex = array.length - 1
  switch
    when index < 0 then maxIndex
    when index > maxIndex then 0
    else index

module.exports =
class PaneContainer extends Model
  serializationVersion: 1
  root: null
  stoppedChangingActivePaneItemDelay: 100
  stoppedChangingActivePaneItemTimeout: null

  constructor: (params) ->
    super

    {@config, applicationDelegate, notificationManager, deserializerManager} = params
    @emitter = new Emitter
    @subscriptions = new CompositeDisposable
    @itemRegistry = new ItemRegistry

    @setRoot(new Pane({container: this, @config, applicationDelegate, notificationManager, deserializerManager}))
    @setActivePane(@getRoot())
    @monitorActivePaneItem()
    @monitorPaneItems()

  serialize: (params) ->
    deserializer: 'PaneContainer'
    version: @serializationVersion
    root: @root?.serialize()
    activePaneId: @activePane.id

  deserialize: (state, deserializerManager) ->
    return unless state.version is @serializationVersion
    @setRoot(deserializerManager.deserialize(state.root))
    activePane = find @getRoot().getPanes(), (pane) -> pane.id is state.activePaneId
    @setActivePane(activePane ? @getPanes()[0])
    @destroyEmptyPanes() if @config.get('core.destroyEmptyPanes')

  onDidChangeRoot: (fn) ->
    @emitter.on 'did-change-root', fn

  observeRoot: (fn) ->
    fn(@getRoot())
    @onDidChangeRoot(fn)

  onDidAddPane: (fn) ->
    @emitter.on 'did-add-pane', fn

  observePanes: (fn) ->
    fn(pane) for pane in @getPanes()
    @onDidAddPane ({pane}) -> fn(pane)

  onDidDestroyPane: (fn) ->
    @emitter.on 'did-destroy-pane', fn

  onWillDestroyPane: (fn) ->
    @emitter.on 'will-destroy-pane', fn

  onDidChangeActivePane: (fn) ->
    @emitter.on 'did-change-active-pane', fn

  observeActivePane: (fn) ->
    fn(@getActivePane())
    @onDidChangeActivePane(fn)

  onDidAddPaneItem: (fn) ->
    @emitter.on 'did-add-pane-item', fn

  observePaneItems: (fn) ->
    fn(item) for item in @getPaneItems()
    @onDidAddPaneItem ({item}) -> fn(item)

  onDidChangeActivePaneItem: (fn) ->
    @emitter.on 'did-change-active-pane-item', fn

  onDidStopChangingActivePaneItem: (fn) ->
    @emitter.on 'did-stop-changing-active-pane-item', fn

  observeActivePaneItem: (fn) ->
    fn(@getActivePaneItem())
    @onDidChangeActivePaneItem(fn)

  onWillDestroyPaneItem: (fn) ->
    @emitter.on 'will-destroy-pane-item', fn

  onDidDestroyPaneItem: (fn) ->
    @emitter.on 'did-destroy-pane-item', fn

  getRoot: -> @root

  setRoot: (@root) ->
    @root.setParent(this)
    @root.setContainer(this)
    @emitter.emit 'did-change-root', @root
    if not @getActivePane()? and isPane(@root)
      @setActivePane(@root)

  replaceChild: (oldChild, newChild) ->
    throw new Error("Replacing non-existent child") unless oldChild is @root
    @setRoot(newChild)

  getPanes: ->
    @getRoot().getPanes()

  getPaneItems: ->
    @getRoot().getItems()

  getActivePane: ->
    @activePane

  hasPane: (pane) ->
    pane in @getPanes()

  isActivePane: (pane) ->
    pane is @activePane

  setActivePane: (pane) ->
    unless @isActivePane(pane)
      throw new Error("Setting active pane that is not present in pane container") unless @hasPane(pane)
      @activePane = pane
      @emitter.emit 'did-change-active-pane', @activePane
    @activePane

  getActivePaneItem: ->
    @getActivePane().getActiveItem()

  paneForURI: (uri) ->
    find @getPanes(), (pane) -> pane.itemForURI(uri)?

  paneForItem: (item) ->
    find @getPanes(), (pane) -> pane.hasItem(item)

  saveAll: ->
    pane.saveItems() for pane in @getPanes()
    return

  confirmClose: (options) ->
    allSaved = true

    for pane in @getPanes()
      for item in pane.getItems()
        unless pane.promptToSaveItem(item, options)
          allSaved = false
          break

    allSaved

  activatePaneInDirection: (direction) ->
    panes = @getPanes()
    if panes.length > 1
      currentIndex = panes.indexOf(@activePane)
      newActiveIndex = switch direction
        when 'next' then currentIndex + 1
        when 'previous' then currentIndex - 1
      newActiveIndex = getValidIndexForArray(newActiveIndex, panes)
      panes[newActiveIndex].activate()
      true
    else
      false

  activateNextPane: -> @activatePaneInDirection('next')

  activatePreviousPane: -> @activatePaneInDirection('previous')

  moveActiveItemToPane: (destPane) ->
    item = @activePane.getActiveItem()
    @activePane.moveItemToPane(item, destPane)
    destPane.setActiveItem(item)

  copyActiveItemToPane: (destPane) ->
    item = @activePane.copyActiveItem()
    destPane.activateItem(item)

  destroyEmptyPanes: ->
    pane.destroy() for pane in @getPanes() when pane.isEmpty()
    return

  willDestroyPaneItem: (event) ->
    @emitter.emit 'will-destroy-pane-item', event

  didDestroyPaneItem: (event) ->
    @emitter.emit 'did-destroy-pane-item', event

  didAddPane: (event) ->
    @emitter.emit 'did-add-pane', event

  willDestroyPane: (event) ->
    @emitter.emit 'will-destroy-pane', event

  didDestroyPane: (event) ->
    @emitter.emit 'did-destroy-pane', event

  # Called by Model superclass when destroyed
  destroyed: ->
    @cancelStoppedChangingActivePaneItemTimeout()
    pane.destroy() for pane in @getPanes()
    @subscriptions.dispose()
    @emitter.dispose()

  cancelStoppedChangingActivePaneItemTimeout: ->
    if @stoppedChangingActivePaneItemTimeout?
      clearTimeout(@stoppedChangingActivePaneItemTimeout)

  monitorActivePaneItem: ->
    childSubscription = null

    @subscriptions.add @observeActivePane (activePane) =>
      if childSubscription?
        @subscriptions.remove(childSubscription)
        childSubscription.dispose()

      childSubscription = activePane.observeActiveItem (activeItem) =>
        @emitter.emit 'did-change-active-pane-item', activeItem
        @cancelStoppedChangingActivePaneItemTimeout()
        stoppedChangingActivePaneItemCallback = =>
          @stoppedChangingActivePaneItemTimeout = null
          @emitter.emit 'did-stop-changing-active-pane-item', activeItem
        @stoppedChangingActivePaneItemTimeout =
          setTimeout(
            stoppedChangingActivePaneItemCallback,
            @stoppedChangingActivePaneItemDelay)

      @subscriptions.add(childSubscription)

  monitorPaneItems: ->
    @subscriptions.add @observePanes (pane) =>
      for item, index in pane.getItems()
        @addedPaneItem(item, pane, index)

      pane.onDidAddItem ({item, index, moved}) =>
        @addedPaneItem(item, pane, index) unless moved

      pane.onDidRemoveItem ({item, moved}) =>
        @removedPaneItem(item) unless moved

  addedPaneItem: (item, pane, index) ->
    @itemRegistry.addItem(item)
    @emitter.emit 'did-add-pane-item', {item, pane, index}

  removedPaneItem: (item) ->
    @itemRegistry.removeItem(item)
