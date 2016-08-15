{CompositeDisposable} = require 'event-kit'
PaneResizeHandleElement = require './pane-resize-handle-element' # [t9md] unused but removing this line make spec fail why?

class PaneAxisElement extends HTMLElement
  attachedCallback: ->
    @subscriptions ?= @subscribeToModel()
    @childAdded({child, index}) for child, index in @model.getChildren()

  detachedCallback: ->
    @subscriptions.dispose()
    @subscriptions = null
    @childRemoved({child}) for child in @model.getChildren()

  initialize: (@model, {@views}) ->
    throw new Error("Must pass a views parameter when initializing TextEditorElements") unless @views?
    @subscriptions ?= @subscribeToModel()
    @childAdded({child, index}) for child, index in @model.getChildren()

    switch @model.getOrientation()
      when 'horizontal'
        @classList.add('horizontal', 'pane-row')
      when 'vertical'
        @classList.add('vertical', 'pane-column')
    this

  subscribeToModel: ->
    new CompositeDisposable(
      @model.onDidAddChild(@childAdded.bind(this)),
      @model.onDidRemoveChild(@childRemoved.bind(this)),
      @model.onDidReplaceChild(@childReplaced.bind(this)),
      @model.observeFlexScale(@flexScaleChanged.bind(this))
    )

  isPaneResizeHandleElement: (element) ->
    element?.nodeName.toLowerCase() is 'atom-pane-resize-handle'

  childAdded: ({child, index}) ->
    view = @views.getView(child)
    @insertBefore(view, @children[index * 2])
    @addPaneResizeHandleElementForView(view)

  childRemoved: ({child}) ->
    view = @views.getView(child)
    @removePaneResizeHandleElementForView(view)
    view.remove()

  addPaneResizeHandleElementForView: (view) ->
    insertPaneResizeHandleElementForView = (element, referenceNode) =>
      if element? and not @isPaneResizeHandleElement(element)
        resizeHandle = document.createElement('atom-pane-resize-handle')
        @insertBefore(resizeHandle, referenceNode)

    insertPaneResizeHandleElementForView(view.previousSibling, view)
    insertPaneResizeHandleElementForView(view.nextSibling, view.nextSibling)

  removePaneResizeHandleElementForView: ({previousSibling}) ->
    if previousSibling? and @isPaneResizeHandleElement(previousSibling)
      previousSibling.remove()


  childReplaced: ({index, oldChild, newChild}) ->
    focusedElement = document.activeElement if @hasFocus()
    @childRemoved({child: oldChild, index})
    @childAdded({child: newChild, index})
    focusedElement?.focus() if document.activeElement is document.body

  flexScaleChanged: (flexScale) -> @style.flexGrow = flexScale

  hasFocus: ->
    this is document.activeElement or @contains(document.activeElement)

module.exports = PaneAxisElement = document.registerElement 'atom-pane-axis', prototype: PaneAxisElement.prototype
