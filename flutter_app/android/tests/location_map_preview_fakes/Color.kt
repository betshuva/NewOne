package android.graphics

object Color {
    fun rgb(red: Int, green: Int, blue: Int): Int =
        (255 shl 24) or (red shl 16) or (green shl 8) or blue
}
