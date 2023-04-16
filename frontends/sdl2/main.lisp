(defpackage :lem-sdl2
  (:use :cl
        :lem-sdl2/key
        :lem-sdl2/font)
  (:export :change-font))
(in-package :lem-sdl2)

(defconstant +display-width+ 100)
(defconstant +display-height+ 40)

(defmacro with-bindings (bindings &body body)
  `(let ,bindings
     (let ((bt:*default-special-bindings*
             (list* ,@(loop :for (var) :in bindings
                            :collect `(cons ',var ,var))
                    bt:*default-special-bindings*)))
       ,@body)))

(defun call-with-debug (log-function body-function)
  (funcall log-function)
  (handler-bind ((error (lambda (e)
                          (log:info "~A"
                                    (with-output-to-string (out)
                                      (format out "~A~%" e)
                                      (uiop:print-backtrace :condition e :stream out))))))
    (funcall body-function)))

(defmacro with-debug ((&rest args) &body body)
  `(call-with-debug (lambda () (log:debug ,@args))
                    (lambda () ,@body)))

(defun create-texture (renderer width height)
  (sdl2:create-texture renderer
                       sdl2:+pixelformat-rgba8888+
                       sdl2-ffi:+sdl-textureaccess-target+
                       width
                       height))

(defun get-character-size (font)
  (let* ((surface (sdl2-ttf:render-text-solid font "A" 0 0 0 0))
         (width (sdl2:surface-width surface))
         (height (sdl2:surface-height surface)))
    (list width height)))

(defclass sdl2 (lem:implementation)
  ()
  (:default-initargs
   :name :sdl2
   :native-scroll-support nil
   :redraw-after-modifying-floating-window t))

(defvar *display*)

(defclass display ()
  ((mutex :initform (bt:make-lock "lem-sdl2 display mutex")
          :reader display-mutex)
   (font-config :initarg :font-config
                :accessor display-font-config)
   (latin-font :initarg :latin-font
               :accessor display-latin-font)
   (latin-bold-font :initarg :latin-bold-font
                    :accessor display-latin-bold-font)
   (unicode-font :initarg :unicode-font
                 :accessor display-unicode-font)
   (unicode-bold-font :initarg :unicode-bold-font
                      :accessor display-unicode-bold-font)
   (renderer :initarg :renderer
             :reader display-renderer)
   (texture :initarg :texture
            :accessor display-texture)
   (window :initarg :window
           :reader display-window)
   (char-width :initarg :char-width
               :accessor display-char-width)
   (char-height :initarg :char-height
                :accessor display-char-height)
   (foreground-color :initform (lem:make-color #xff #xff #xff)
                     :accessor display-foreground-color)
   (background-color :initform (lem:make-color 0 0 0)
                     :accessor display-background-color)))

(defun char-width () (display-char-width *display*))
(defun char-height () (display-char-height *display*))

(defun call-with-renderer (function)
  (bt:with-lock-held ((display-mutex *display*))
    (funcall function)))

(defmacro with-renderer (() &body body)
  `(call-with-renderer (lambda () ,@body)))

(defmethod display-font ((display display) &key latin bold)
  (if bold
      (if latin
          (display-latin-bold-font display)
          (display-unicode-bold-font display))
      (if latin
          (display-latin-font display)
          (display-unicode-font display))))

(defmethod update-display ((display display))
  (sdl2:render-present (display-renderer display)))

(defmethod display-width ((display display))
  (nth-value 0 (sdl2:get-window-size (display-window display))))

(defmethod display-height ((display display))
  (nth-value 1 (sdl2:get-window-size (display-window display))))

(defmethod set-render-color ((display display) color)
  (sdl2:set-render-draw-color (display-renderer display)
                              (lem:color-red color)
                              (lem:color-green color)
                              (lem:color-blue color)
                              0))

(defun attribute-foreground-color (attribute)
  (or (and attribute
           (lem:parse-color (lem:attribute-foreground attribute)))
      (display-foreground-color *display*)))

(defun attribute-background-color (attribute)
  (or (and attribute
           (lem:parse-color (lem:attribute-background attribute)))
      (display-background-color *display*)))

(defun render-line (x1 y1 x2 y2 &key color)
  (set-render-color  *display* color)
  (sdl2:render-draw-line (display-renderer *display*) x1 y1 x2 y2))

(defun render (renderer texture width height x y)
  (sdl2:with-rects ((dest-rect x y width height))
    (sdl2:render-copy-ex renderer
                         texture
                         :source-rect nil
                         :dest-rect dest-rect
                         :flip (list :none))))

(defun render-text (text x y &key color bold)
  (let ((x (* x (char-width)))
        (y (* y (char-height))))
    (loop :for c :across text
          :for i :from 0
          :for latin-p := (<= (char-code c) 128)
          :do (cffi:with-foreign-string (c-string (string c))
                (let* ((red (lem:color-red color))
                       (green (lem:color-green color))
                       (blue (lem:color-blue color))
                       (surface (sdl2-ttf:render-utf8-blended (display-font *display* :latin latin-p :bold bold)
                                                              c-string
                                                              red
                                                              green
                                                              blue
                                                              0))
                       (text-width (sdl2:surface-width surface))
                       (text-height (sdl2:surface-height surface))
                       (texture (sdl2:create-texture-from-surface (display-renderer *display*)
                                                                  surface)))
                  (render (display-renderer *display*) texture text-width text-height x y)
                  (sdl2:destroy-texture texture)))
              (incf x (if latin-p
                          (char-width)
                          (* (char-width) 2))))))

(defun render-fill-text (text x y &key attribute)
  (let ((width (lem:string-width text))
        (underline (and attribute (lem:attribute-underline-p attribute)))
        (bold (and attribute (lem:attribute-bold-p attribute)))
        (reverse (and attribute (lem:attribute-reverse-p attribute))))
    (let ((background-color (if reverse
                                (attribute-foreground-color attribute)
                                (attribute-background-color attribute)))
          (foreground-color (if reverse
                                (attribute-background-color attribute)
                                (attribute-foreground-color attribute))))
      (render-fill-rect x y width 1 :color background-color)
      (render-text text x y :color foreground-color :bold bold)
      (when underline
        (render-line (* x (char-width))
                     (- (* (1+ y) (char-height)) 1)
                     (* (+ x width) (char-width))
                     (- (* (1+ y) (char-height)) 1)
                     :color foreground-color)))))

(defun render-fill-rect (x y width height &key color)
  (let ((x (* x (char-width)))
        (y (* y (char-height)))
        (width (* width (char-width)))
        (height (* height (char-height))))
    (sdl2:with-rects ((rect x y width height))
      (set-render-color *display* color)
      (sdl2:render-fill-rect (display-renderer *display*) rect))))

(defun render-fill-rect-by-pixels (x y width height &key color)
  (sdl2:with-rects ((rect x y width height))
    (set-render-color *display* color)
    (sdl2:render-fill-rect (display-renderer *display*) rect)))

(defun render-border (x y w h)
  (sdl2:with-rects ((up-rect (- (* x (char-width)) (floor (char-width) 2))
                             (- (* y (char-height)) (floor (char-height) 2))
                             (* (+ w 1) (char-width))
                             (floor (char-height) 2))
                    (left-rect (- (* x (char-width)) (floor (char-width) 2))
                               (- (* y (char-height)) (floor (char-height) 2))
                               (floor (char-width) 2)
                               (* (+ h 1) (char-height)))
                    (right-rect (* (+ x w) (char-width))
                                (+ (* (1- y) (char-height)) (floor (char-height) 2))
                                (floor (char-width) 2)
                                (* (+ h 1) (char-height)))
                    (down-rect (- (* x (char-width)) (floor (char-width) 2))
                               (* (+ y h) (char-height))
                               (* (+ w 1) (char-width))
                               (floor (char-height) 2))

                    (border-rect (- (* x (char-width)) (floor (char-width) 2))
                                 (- (* y (char-height)) (floor (char-height) 2))
                                 (* (+ 1 w) (char-width))
                                 (* (+ 1 h) (char-height))))

    (set-render-color *display* (display-background-color *display*))
    (sdl2:render-fill-rect (display-renderer *display*) up-rect)
    (sdl2:render-fill-rect (display-renderer *display*) down-rect)
    (sdl2:render-fill-rect (display-renderer *display*) left-rect)
    (sdl2:render-fill-rect (display-renderer *display*) right-rect)

    (set-render-color *display* (display-foreground-color *display*))
    (sdl2:render-draw-rect (display-renderer *display*) border-rect)))

(defmethod update-texture ((display display))
  (bt:with-lock-held ((display-mutex display))
    (sdl2:destroy-texture (display-texture display))
    (setf (display-texture display)
          (create-texture (display-renderer display)
                          (display-width display)
                          (display-height display)))))

(defun notify-resize ()
  (sdl2:set-render-target (display-renderer *display*) (display-texture *display*))
  (set-render-color *display* (display-background-color *display*))
  (sdl2:render-clear (display-renderer *display*))
  (lem:send-event :resize))

(defun change-font (font-config)
  (let ((display *display*))
    (let ((font-config (merge-font-config font-config (display-font-config display))))
      (sdl2-ttf:close-font (display-latin-font display))
      (sdl2-ttf:close-font (display-latin-bold-font display))
      (sdl2-ttf:close-font (display-unicode-font display))
      (sdl2-ttf:close-font (display-unicode-bold-font display))
      (multiple-value-bind (latin-font
                            latin-bold-font
                            unicode-font
                            unicode-bold-font)
          (open-font font-config)
        (destructuring-bind (char-width char-height) (get-character-size latin-font)
          (setf (display-char-width display) char-width
                (display-char-height display) char-height)
          (setf (display-font-config display) font-config)
          (setf (display-latin-font display) latin-font
                (display-latin-bold-font display) latin-bold-font
                (display-unicode-font display) unicode-font
                (display-unicode-bold-font display) unicode-bold-font))))
    (notify-resize)))

(defclass view ()
  ((window
    :initarg :window
    :accessor view-window)
   (x
    :initarg :x
    :accessor view-x)
   (y
    :initarg :y
    :accessor view-y)
   (width
    :initarg :width
    :accessor view-width)
   (height
    :initarg :height
    :accessor view-height)
   (use-modeline
    :initarg :use-modeline
    :accessor view-use-modeline)))

(defun create-view (window x y width height use-modeline)
  (make-instance 'view
                 :window window
                 :x x
                 :y y
                 :width width
                 :height height
                 :use-modeline use-modeline))

(defmethod delete-view ((view view))
  nil)

(defmethod render-clear ((view view))
  (render-fill-rect (view-x view)
             (view-y view)
             (view-width view)
             (view-height view)
             :color (display-background-color *display*)))

(defmethod resize ((view view) width height)
  (setf (view-width view) width
        (view-height view) height))

(defmethod move-position ((view view) x y)
  (setf (view-x view) x
        (view-y view) y))

(defmethod render-text-using-view ((view view) x y string attribute)
  (render-fill-text string
                    (+ (view-x view) x)
                    (+ (view-y view) y)
                    :attribute attribute))

(defmethod render-text-to-modeline-using-view ((view view) x y string attribute)
  (render-fill-text string
                    (+ (view-x view) x)
                    (+ (view-y view) (view-height view) y)
                    :attribute attribute))

(defmethod clear-eol ((view view) x y)
  (render-fill-rect (+ (view-x view) x)
             (+ (view-y view) y)
             (- (view-width view) x)
             1
             :color (display-background-color *display*)))

(defmethod clear-eob ((view view) x y)
  (clear-eol view x y)
  (render-fill-rect (view-x view)
             (+ (view-y view) y 1)
             (view-width view)
             (- (view-height view) y 1)
             :color (display-background-color *display*)))

(defvar *modifier* (make-modifier))

(defun on-key-down (keysym)
  (sdl2:hide-cursor)
  (update-modifier *modifier* keysym)
  (alexandria:when-let (key (keysym-to-key keysym))
    (lem:send-event key)))

(defun on-key-up (keysym)
  (update-modifier *modifier* keysym))

(defun on-text-input (text)
  (sdl2:hide-cursor)
  (loop :for c :across text
        :do (multiple-value-bind (sym converted)
                (convert-to-sym c)
              (unless converted
                (lem:send-event
                 (make-key-with-modifier *modifier*
                                         (or sym (string c))))))))

(defun on-mouse-button-down (button x y)
  (sdl2:show-cursor)
  (let ((button
          (cond ((eql button sdl2-ffi:+sdl-button-left+) :button-1)
                ((eql button sdl2-ffi:+sdl-button-right+) :button-3)
                ((eql button sdl2-ffi:+sdl-button-middle+) :button-2))))
    (when button
      (let ((x (floor x (char-width)))
            (y (floor y (char-height))))
        (lem:send-event (lambda ()
                          (lem::handle-mouse-button-down x y button)
                          (lem:redraw-display)))))))

(defun on-mouse-button-up (button x y)
  (sdl2:show-cursor)
  (let ((button
          (cond ((eql button sdl2-ffi:+sdl-button-left+) :button-1)
                ((eql button sdl2-ffi:+sdl-button-right+) :button-3)
                ((eql button sdl2-ffi:+sdl-button-middle+) :button-2))))
    (lem:send-event (lambda ()
                      (lem::handle-mouse-button-up x y button)
                      (lem:redraw-display)))))

(defun on-mouse-motion (x y state)
  (sdl2:show-cursor)
  (when (= sdl2-ffi:+sdl-button-lmask+ (logand state sdl2-ffi:+sdl-button-lmask+))
    (let ((x (floor x (char-width)))
          (y (floor y (char-height))))
      (lem:send-event (lambda ()
                        (lem::handle-mouse-motion x y :button-1)
                        (when (= 0 (lem::event-queue-length))
                          (lem:redraw-display)))))))

(defun on-mouse-wheel (wheel-x wheel-y which direction)
  (declare (ignore which direction))
  (sdl2:show-cursor)
  (multiple-value-bind (x y) (sdl2:mouse-state)
    (let ((x (floor x (char-width)))
          (y (floor y (char-height))))
      (lem:send-event (lambda ()
                        (lem::handle-mouse-wheel x y wheel-x wheel-y)
                        (when (= 0 (lem::event-queue-length))
                          (lem:redraw-display)))))))

(defun event-loop ()
  (sdl2:with-event-loop (:method :wait)
    (:quit ()
     t)
    (:textinput (:text text)
     (on-text-input text))
    (:keydown (:keysym keysym)
     (on-key-down keysym))
    (:keyup (:keysym keysym)
     (on-key-up keysym))
    (:mousebuttondown (:button button :x x :y y)
     (on-mouse-button-down button x y))
    (:mousebuttonup (:button button :x x :y y)
     (on-mouse-button-up button x y))
    (:mousemotion (:x x :y y :state state)
     (on-mouse-motion x y state))
    (:mousewheel (:x x :y y :which which :direction direction)
     (on-mouse-wheel x y which direction))
    (:windowevent (:event event)
     (when (equal event sdl2-ffi:+sdl-windowevent-resized+)
       (update-texture *display*)
       (notify-resize)))
    (:idle ())))

(defun create-display (function)
  (sdl2:with-init (:video)
    (sdl2-ttf:init)
    (let ((font-config (make-font-config)))
      (multiple-value-bind (latin-font
                            latin-bold-font
                            unicode-font
                            unicode-bold-font)
          (open-font font-config)
        (destructuring-bind (char-width char-height) (get-character-size latin-font)
          (let ((window-width (* +display-width+ char-width))
                (window-height (* +display-height+ char-height)))
            (sdl2:with-window (window :title "Lem"
                                      :w window-width
                                      :h window-height
                                      :flags '(:shown :resizable))
              (sdl2:with-renderer (renderer window :index -1 :flags '(:accelerated))
                (let ((texture (create-texture renderer
                                               window-width
                                               window-height)))
                  (with-bindings ((*display* (make-instance 'display
                                                            :font-config font-config
                                                            :latin-font latin-font
                                                            :latin-bold-font latin-bold-font
                                                            :unicode-font unicode-font
                                                            :unicode-bold-font unicode-bold-font
                                                            :renderer renderer
                                                            :window window
                                                            :texture texture
                                                            :char-width char-width
                                                            :char-height char-height)))
                    (sdl2:start-text-input)
                    (funcall function)
                    (event-loop)))))))))))

(defmethod lem-if:invoke ((implementation sdl2) function)
  (create-display (lambda ()
                    (let ((editor-thread
                            (funcall function
                                     ;; initialize
                                     (lambda ())
                                     ;; finalize
                                     (lambda (report)
                                       (declare (ignore report))
                                       (sdl2:push-quit-event)))))
                      (declare (ignore editor-thread))
                      nil))))

(defmethod lem-if:get-background-color ((implementation sdl2))
  (with-debug ("lem-if:get-background-color")
    (display-background-color *display*)))

(defmethod lem-if:update-foreground ((implementation sdl2) color)
  (with-debug ("lem-if:update-foreground" color)
    (setf (display-background-color *display*) color)
    ;; TODO: redraw
    ))

(defmethod lem-if:update-background ((implementation sdl2) color)
  (with-debug ("lem-if:update-background" color)
    (setf (display-foreground-color *display*) color)
    ;; TODO: redraw
    ))

(defmethod lem-if:display-width ((implementation sdl2))
  (with-debug ("lem-if:display-width")
    (with-renderer ()
      (floor (display-width *display*) (char-width)))))

(defmethod lem-if:display-height ((implementation sdl2))
  (with-debug ("lem-if:display-height")
    (with-renderer ()
      (floor (display-height *display*) (char-height)))))

(defmethod lem-if:make-view ((implementation sdl2) window x y width height use-modeline)
  (with-debug ("lem-if:make-view" window x y width height use-modeline)
    (with-renderer ()
      (create-view window x y width height use-modeline))))

(defmethod lem-if:delete-view ((implementation sdl2) view)
  (with-debug ("lem-if:delete-view")
    (with-renderer ()
      (delete-view view))))

(defmethod lem-if:clear ((implementation sdl2) view)
  (with-debug ("lem-if:clear" view)
    (with-renderer ()
      (render-clear view))))

(defmethod lem-if:set-view-size ((implementation sdl2) view width height)
  (with-debug ("lem-if:set-view-size" view width height)
    (with-renderer ()
      (resize view width height))))

(defmethod lem-if:set-view-pos ((implementation sdl2) view x y)
  (with-debug ("lem-if:set-view-pos" view x y)
    (with-renderer ()
      (move-position view x y))))

(defmethod lem-if:print ((implementation sdl2) view x y string attribute-or-name)
  (with-debug ("lem-if:print" view x y string attribute-or-name)
    (with-renderer ()
      (let ((attribute (lem:ensure-attribute attribute-or-name nil)))
        (render-text-using-view view x y string attribute)))))

(defmethod lem-if:print-modeline ((implementation sdl2) view x y string attribute-or-name)
  (with-debug ("lem-if:print-modeline" view x y string attribute-or-name)
    (with-renderer ()
      (let ((attribute (lem:ensure-attribute attribute-or-name nil)))
        (render-text-to-modeline-using-view view x y string attribute)))))

(defmethod lem-if:clear-eol ((implementation sdl2) view x y)
  (with-debug ("lem-if:clear-eol" view x y)
    (with-renderer ()
      (clear-eol view x y))))

(defmethod lem-if:clear-eob ((implementation sdl2) view x y)
  (with-debug ("lem-if:clear-eob" view x y)
    (with-renderer ()
      (clear-eob view x y))))

(defun border-exists-p (window)
  (and (lem:floating-window-p window)
       (lem:floating-window-border window)
       (< 0 (lem:floating-window-border window))))

(defun draw-border (view)
  (when (border-exists-p (view-window view))
    (render-border (view-x view)
                   (view-y view)
                   (view-width view)
                   (view-height view))))

(defun draw-leftside-border (view)
  (when (and (< 0 (view-x view))
             (lem::window-use-modeline-p (view-window view)))
    (let ((attribute (lem:ensure-attribute 'lem:modeline-inactive)))
      (render-fill-rect (1- (view-x view))
                 (view-y view)
                 1
                 (1+ (view-height view))
                 :color (attribute-background-color attribute))

      (render-fill-rect-by-pixels (+ (* (1- (view-x view)) (char-width))
                              (floor (char-width) 2)
                              -1)
                           (* (view-y view) (char-height))
                           2
                           (* (+ (view-y view) (view-height view)) (char-height))
                           :color (attribute-foreground-color attribute)))))

(defmethod lem-if:redraw-view-after ((implementation sdl2) view)
  (with-debug ("lem-if:redraw-view-after" view)
    (with-renderer ()
      (draw-border view)
      (draw-leftside-border view))))

(defmethod lem-if::will-update-display ((implementation sdl2))
  (with-debug ("will-update-display")
    (with-renderer ()
      (sdl2:set-render-target (display-renderer *display*) (display-texture *display*)))))

(defmethod lem-if:update-display ((implementation sdl2))
  (with-debug ("lem-if:update-display")
    (with-renderer ()
      (sdl2:set-render-target (display-renderer *display*) nil)
      (sdl2:render-copy (display-renderer *display*) (display-texture *display*))
      (update-display *display*))))

(defmethod lem-if:scroll ((implementation sdl2) view n)
  (with-debug ("lem-if:scroll" view n)
    ))

(defmethod lem-if:clipboard-paste ((implementation sdl2))
  (with-debug ("clipboard-paste")
    (with-renderer ()
      (sdl2-ffi.functions:sdl-get-clipboard-text))))

(defmethod lem-if:clipboard-copy ((implementation sdl2) text)
  (with-debug ("clipboard-copy")
    (with-renderer ()
      (sdl2-ffi.functions:sdl-set-clipboard-text text))))

(defmethod lem-if:increase-font-size ((implementation sdl2))
  (with-debug ("increase-font-size")
    (with-renderer ()
      (let ((font-config (display-font-config *display*)))
        (change-font (change-size font-config
                                  (1+ (font-config-size font-config))))))))

(defmethod lem-if:decrease-font-size ((implementation sdl2))
  (with-debug ("decrease-font-size")
    (with-renderer ()
      (let ((font-config (display-font-config *display*)))
        (change-font (change-size font-config
                                  (1- (font-config-size font-config))))))))

(pushnew :lem-sdl2 *features*)
