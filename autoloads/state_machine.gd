# A state machine autoload
extends Node

enum STATE { IDLE, SCROLLING, DISTORTING, FOCUSING, PRINTING, REVERTING }
var state = STATE.IDLE
