package com.future.screenShare

import android.app.Application
import android.content.Intent
import android.content.Context
import com.future.screenShare.WakeLockService

class MainApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        // 不在Application中启动服务，避免BackgroundServiceStartNotAllowedException
        // 服务将在主Activity中启动
    }
}