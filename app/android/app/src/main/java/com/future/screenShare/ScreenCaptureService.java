package com.future.screenShare;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.Intent;
import android.content.pm.ServiceInfo;
import android.os.Build;
import android.os.IBinder;
import android.util.Log;

import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;

/**
 * 屏幕采集前台服务。
 * Android 14+(API 34)起,必须先启动 foregroundServiceType=mediaProjection 的前台服务
 * 并完成 startForeground(),才能调用 getMediaProjection(),否则会抛 SecurityException
 * 导致用户点击"立即开始"后应用闪退。
 */
public class ScreenCaptureService extends Service {
    private static final String TAG = "ScreenCaptureService";
    private static final String CHANNEL_ID = "screen_capture_channel";
    private static final int NOTIFICATION_ID = 1;

    /** startForeground 完成信号,供插件等待(Android 14+ 前置条件) */
    private static final CountDownLatch foregroundLatch = new CountDownLatch(1);

    public static boolean awaitForeground(long timeout, TimeUnit unit) {
        try {
            return foregroundLatch.await(timeout, unit);
        } catch (InterruptedException e) {
            return false;
        }
    }

    @Override
    public void onCreate() {
        super.onCreate();
        createNotificationChannel();
        // Android 14+ 要求:project_media 授权(用户点"立即开始"后)生效时才能以
        // mediaProjection 类型 startForeground,否则抛 SecurityException。
        // 授权生效存在毫秒级窗口,失败时短暂重试,避免应用闪退。
        for (int attempt = 0; attempt < 10; attempt++) {
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    startForeground(NOTIFICATION_ID, createNotification(),
                            ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION);
                } else {
                    startForeground(NOTIFICATION_ID, createNotification());
                }
                foregroundLatch.countDown();
                Log.i(TAG, "mediaProjection 前台服务已就绪 (attempt=" + (attempt + 1) + ")");
                return;
            } catch (SecurityException e) {
                Log.w(TAG, "startForeground 未获 mediaProjection 授权,重试 " + (attempt + 1));
                try {
                    Thread.sleep(300);
                } catch (InterruptedException ie) {
                    Thread.currentThread().interrupt();
                    break;
                }
            }
        }
        Log.e(TAG, "mediaProjection 授权始终未生效,停止服务");
        stopSelf();
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        // 不随进程死亡自动重启:重启后的新进程没有 mediaProjection 授权,会再次崩溃
        return START_NOT_STICKY;
    }

    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }

    @Override
    public void onDestroy() {
        Log.i(TAG, "前台服务已停止");
        super.onDestroy();
    }

    private void createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            NotificationChannel channel = new NotificationChannel(
                CHANNEL_ID,
                "Screen Capture Service",
                NotificationManager.IMPORTANCE_LOW
            );
            NotificationManager manager = getSystemService(NotificationManager.class);
            if (manager != null) {
                manager.createNotificationChannel(channel);
            }
        }
    }

    private Notification createNotification() {
        Intent notificationIntent = getPackageManager().getLaunchIntentForPackage(getPackageName());
        PendingIntent pendingIntent;
        int pendingFlags = PendingIntent.FLAG_CANCEL_CURRENT | PendingIntent.FLAG_IMMUTABLE;
        if (notificationIntent != null) {
            pendingIntent = PendingIntent.getActivity(this, 0, notificationIntent, pendingFlags);
        } else {
            pendingIntent = PendingIntent.getActivity(this, 0, new Intent(), pendingFlags);
        }

        Notification.Builder builder;
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            builder = new Notification.Builder(this, CHANNEL_ID);
        } else {
            builder = new Notification.Builder(this);
        }

        return builder
            .setContentTitle("屏幕共享服务")
            .setContentText("正在共享屏幕...")
            .setSmallIcon(android.R.drawable.ic_menu_camera)
            .setContentIntent(pendingIntent)
            .build();
    }
}
