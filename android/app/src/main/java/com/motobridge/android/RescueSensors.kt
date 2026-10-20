package com.motobridge.android

import android.content.Context
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager

/**
 * Sensores del teléfono para el MODO RESCATE (localizar a una persona atrapada
 * sin GPS: terremoto, derrumbe, cueva).
 *
 * - Barómetro (TYPE_PRESSURE): da la presión en hPa. Comparando la presión de
 *   la víctima con la del rescatista se estima la diferencia de ALTURA en metros
 *   y, con ella, los PISOS (≈3 m por piso). Funciona bajo tierra o entre
 *   escombros, porque no depende de satélites.
 * - Brújula (TYPE_ROTATION_VECTOR): rumbo magnético al que apunta el teléfono.
 *   No apunta a la víctima por sí sola; sirve para que el rescatista anote en
 *   qué rumbo SUBE la señal mientras gira.
 *
 * Honestidad de precisión: el barómetro deriva lentamente con el clima y el
 * concreto distorsiona la brújula. Es orientación aproximada, no una posición
 * exacta.
 */
class RescueSensors(context: Context) : SensorEventListener {

    companion object {
        const val METERS_PER_FLOOR = 3.0

        /** Convierte una diferencia de altura (m) en número de pisos con signo. */
        fun floorsFrom(metersDelta: Double): Int =
            Math.round(metersDelta / METERS_PER_FLOOR).toInt()

        /** Altura relativa (m) a partir de dos presiones en hPa (barométrica).
         *  Fórmula estándar: ~8.3 m por hPa cerca del nivel del mar. */
        fun altitudeMeters(pressureHpa: Double, seaLevelHpa: Double = 1013.25): Double =
            SensorManager.getAltitude(seaLevelHpa.toFloat(), pressureHpa.toFloat()).toDouble()
    }

    private val sm = context.getSystemService(Context.SENSOR_SERVICE) as SensorManager
    private val pressureSensor: Sensor? = sm.getDefaultSensor(Sensor.TYPE_PRESSURE)
    private val rotationSensor: Sensor? = sm.getDefaultSensor(Sensor.TYPE_ROTATION_VECTOR)

    /** ¿El dispositivo tiene barómetro? (no todos los Android lo traen). */
    val hasBarometer: Boolean get() = pressureSensor != null

    /** Altura relativa en metros (desde el nivel del mar estándar). null si no hay dato. */
    var relativeAltitudeMeters: Double? = null
        private set
    /** Presión barométrica en hPa (diagnóstico). null si no hay dato. */
    var pressureHpa: Double? = null
        private set
    /** Rumbo magnético del teléfono en grados (0 = Norte). null si no disponible. */
    var headingDegrees: Double? = null
        private set

    /** Callback para que el controlador refresque la UI al llegar lecturas. */
    var onUpdate: (() -> Unit)? = null

    private var running = false

    fun start() {
        if (running) return
        running = true
        pressureSensor?.let { sm.registerListener(this, it, SensorManager.SENSOR_DELAY_UI) }
        rotationSensor?.let { sm.registerListener(this, it, SensorManager.SENSOR_DELAY_UI) }
    }

    fun stop() {
        if (!running) return
        running = false
        sm.unregisterListener(this)
        relativeAltitudeMeters = null
        pressureHpa = null
        headingDegrees = null
    }

    override fun onSensorChanged(event: SensorEvent) {
        when (event.sensor.type) {
            Sensor.TYPE_PRESSURE -> {
                val hpa = event.values[0].toDouble()
                pressureHpa = hpa
                relativeAltitudeMeters = altitudeMeters(hpa)
                onUpdate?.invoke()
            }
            Sensor.TYPE_ROTATION_VECTOR -> {
                val rot = FloatArray(9)
                SensorManager.getRotationMatrixFromVector(rot, event.values)
                val orientation = FloatArray(3)
                SensorManager.getOrientation(rot, orientation)
                var azimuth = Math.toDegrees(orientation[0].toDouble())
                if (azimuth < 0) azimuth += 360.0
                headingDegrees = azimuth
                onUpdate?.invoke()
            }
        }
    }

    override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) {}
}
