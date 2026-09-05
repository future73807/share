package com.future.screenShare;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.Intent;
import android.content.pm.ServiceInfo;
import android.media.AudioAttributes;
import android.media.AudioFormat;
import android.media.AudioPlaybackCaptureConfiguration;
import android.media.AudioRecord;
import android.media.projection.MediaProjection;
import android.media.projection.MediaProjectionManager;
import android.os.Build;
import android.os.Handler;
import android.os.IBinder;
import android.os.Looper;
import android.util.Log;

import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;

/**
 * 屏幕采集前台服务(Android 10+ 官方音频捕获标准实现):
 * 1. 视频采集:Android 14+ 要求先由本服务完成 startForeground(mediaProjection)
 * 2. 声音内录:授权数据(resultCode + resultData)通过 Intent 传入本服务,
 *    在 onStartCommand(前台服务上下文)中 getMediaProjection 并创建
 *    AudioPlaybackCapture 音频采集,数据经 feedSystemAudio 注入 WebRTC 上行。
 */
public class ScreenCaptureService extends Service {
    private static final String TAG = "ScreenCaptureService";
    private static final String CHANNEL_ID = "screen_capture_channel";
    private static final int NOTIFICATION_ID = 1;

    public static final String ACTION_START = "com.future.screenShare.START";
    public static final String ACTION_START_AUDIO = "com.future.screenShare.START_AUDIO";
    public static final String ACTION_STOP_AUDIO = "com.future.screenShare.STOP_AUDIO";
    public static final String EXTRA_RESULT_CODE = "resultCode";
    public static final String EXTRA_RESULT_DATA = "resultData";

    private static final java.util.concurrent.CountDownLatch foregroundLatch = new java.util.concurrent.CountDownLatch(1);

    private AudioRecord audioRecord;
    private java.util.concurrent.ExecutorService audioExecutor;
    private volatile boolean audioCapturing = false;
    private MediaProjection audioProjection;
    private android.os.Handler mainHandler;

    public static boolean awaitForeground(long timeout, java.util.concurrent.TimeUnit unit) {
        try {
            return foregroundLatch.await(timeout, unit);
        } catch (InterruptedException e) {
            return false;
        }
    }

    @Override
    public void onCreate() {
        super.onCreate();
        mainHandler = new android.os.Handler(android.os.Looper.getMainLooper());
        createNotificationChannel();
        for (int attempt = 0; attempt < 10; attempt++) {
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    startForeground(NOTIFICATION_ID, createNotification(),
                            android.content.pm.ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION);
                } else {
                    startForeground(NOTIFICATION_ID, createNotification());
                }
                foregroundLatch.countDown();
                Log.i(TAG, "FGS ready attempt=" + (attempt + 1));
                return;
            } catch (SecurityException e) {
                Log.w(TAG, "startForeground retry " + (attempt + 1));
                try { Thread.sleep(300); } catch (InterruptedException ie) { Thread.currentThread().interrupt(); break; }
            }
        }
        Log.e(TAG, "mediaProjection auth not effective, stopping");
        stopSelf();
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        if (intent == null || intent.getAction() == null) {
            return START_NOT_STICKY;
        }
        switch (intent.getAction()) {
            case ACTION_START_AUDIO:
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    startAudioCaptureFromIntent(intent);
                }
                break;
            case ACTION_STOP_AUDIO:
                stopAudioCapture();
                break;
            default:
                break;
        }
        return START_NOT_STICKY;
    }

    private void startAudioCaptureFromIntent(Intent intent) {
        stopAudioCapture();
        final int resultCode = intent.getIntExtra(EXTRA_RESULT_CODE, 0);
        final Intent resultData = intent.getParcelableExtra(EXTRA_RESULT_DATA);
        if (resultData == null) {
            Log.e(TAG, "audio consent data empty");
            return;
        }
        MediaProjectionManager mpm = (MediaProjectionManager) getBaseContext().getSystemService(MEDIA_PROJECTION_SERVICE);
        if (mpm == null) {
            Log.e(TAG, "no MediaProjectionManager");
            return;
        }
        audioExecutor = Executors.newSingleThreadExecutor();
        audioExecutor.execute(new Runnable() {
            @Override
            public void run() {
                try {
                    MediaProjection projection = mpm.getMediaProjection(resultCode, resultData);
                    if (projection == null) {
                        Log.e(TAG, "audio projection null");
                        return;
                    }
                    audioProjection = projection;
                    AudioPlaybackCaptureConfiguration config =
                            new AudioPlaybackCaptureConfiguration.Builder(projection)
                                    .addMatchingUsage(android.media.AudioAttributes.USAGE_MEDIA)
                                    .addMatchingUsage(android.media.AudioAttributes.USAGE_GAME)
                                    .addMatchingUsage(android.media.AudioAttributes.USAGE_UNKNOWN)
                                    .addMatchingUsage(android.media.AudioAttributes.USAGE_ASSISTANCE_NAVIGATION_GUIDANCE)
                                    .addMatchingUsage(android.media.AudioAttributes.USAGE_ASSISTANCE_SONIFICATION)
                                    .build();
                    AudioFormat format = new AudioFormat.Builder()
                            .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                            .setSampleRate(ScreenAudioMixProcessor.SRC_SAMPLE_RATE)
                            .setChannelMask(AudioFormat.CHANNEL_IN_MONO)
                            .build();
                    int minBuf = AudioRecord.getMinBufferSize(
                            ScreenAudioMixProcessor.SRC_SAMPLE_RATE,
                            AudioFormat.CHANNEL_IN_MONO,
                            AudioFormat.ENCODING_PCM_16BIT);
                    if (minBuf < 2048) minBuf = 2048;
                    AudioRecord record = new AudioRecord.Builder()
                            .setAudioFormat(format)
                            .setBufferSizeInBytes(minBuf * 4)
                            .setAudioPlaybackCaptureConfig(config)
                            .build();
                    audioRecord = record;
                    audioCapturing = true;
                    record.startRecording();
                    Log.i(TAG, "audio capture started: state=" + record.getState());
                    final short[] buf = new short[2048];
                    long reads = 0;
                    long samples = 0;
                    long lastLog = System.currentTimeMillis();
                    while (audioCapturing) {
                        int n = record.read(buf, 0, buf.length);
                        reads++;
                        if (n > 0) {
                            samples += n;
                            ScreenSharePlugin.feedSystemAudio(buf, n);
                        } else if (n < 0) {
                            Log.e(TAG, "AudioRecord.read " + n + ", stop");
                            break;
                        }
                        long now = System.currentTimeMillis();
                        if (now - lastLog >= 1000) {
                            Log.i(TAG, "audio: reads=" + reads + " samples=" + samples + " lastRead=" + n);
                            lastLog = now;
                        }
                    }
                    Log.w(TAG, "audio thread exit");
                    try { record.stop(); } catch (Exception ignored) {}
                    try { record.release(); } catch (Exception ignored) {}
                    audioRecord = null;
                } catch (Throwable t) {
                    Log.e(TAG, "audio capture exception", t);
                }
            }
        });
    }

    private void stopAudioCapture() {
        audioCapturing = false;
        audioRecord = null;
        if (audioExecutor != null) {
            audioExecutor.shutdownNow();
            audioExecutor = null;
        }
        Log.i(TAG, "audio capture stopped");
    }

    @Override
    public void onDestroy() {
        stopAudioCapture();
        Log.i(TAG, "service destroyed");
        super.onDestroy();
    }

    @Override
    public IBinder onBind(Intent intent) {
        return null;
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
