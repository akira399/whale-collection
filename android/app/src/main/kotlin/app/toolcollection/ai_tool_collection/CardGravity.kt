package app.toolcollection.ai_tool_collection

import android.app.Activity
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.view.Surface
import io.flutter.plugin.common.EventChannel

class CardGravity(private val activity: Activity) : EventChannel.StreamHandler, SensorEventListener {
    private val manager by lazy { activity.getSystemService(SensorManager::class.java) }
    private var sink: EventChannel.EventSink? = null

    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        val sensorManager = manager
        val sensor = sensorManager?.getDefaultSensor(Sensor.TYPE_GRAVITY)
            ?: sensorManager?.getDefaultSensor(Sensor.TYPE_ACCELEROMETER)
        if (sensorManager == null || sensor == null || !sensorManager.registerListener(this, sensor, 33_333)) {
            events.endOfStream()
            return
        }
        sink = events
    }

    override fun onCancel(arguments: Any?) {
        if (sink != null) manager?.unregisterListener(this)
        sink = null
    }

    @Suppress("DEPRECATION")
    override fun onSensorChanged(event: SensorEvent) {
        val lateral = when (activity.windowManager.defaultDisplay.rotation) {
            Surface.ROTATION_90 -> -event.values[1]
            Surface.ROTATION_180 -> -event.values[0]
            Surface.ROTATION_270 -> event.values[1]
            else -> event.values[0]
        }
        sink?.success(doubleArrayOf(lateral.toDouble(), event.values[2].toDouble()))
    }

    override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) = Unit
}
