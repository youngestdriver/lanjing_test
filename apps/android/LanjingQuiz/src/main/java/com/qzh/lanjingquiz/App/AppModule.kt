package com.qzh.lanjingquiz.App

import com.qzh.lanjingquiz.Data.PrefsSettingsStore
import com.qzh.lanjingquiz.Data.SecureStore
import com.qzh.lanjingquiz.Data.SettingsStore
import com.qzh.lanjingquiz.Network.ApiClient
import com.qzh.lanjingquiz.Network.CookieStore
import com.qzh.lanjingquiz.Network.PersistentCookieJar
import com.qzh.lanjingquiz.Network.PrefsCookieStore
import com.qzh.lanjingquiz.Network.TestConfig
import com.qzh.lanjingquiz.Network.UpstreamApi
import dagger.Module
import dagger.Provides
import dagger.hilt.InstallIn
import dagger.hilt.android.qualifiers.ApplicationContext
import dagger.hilt.components.SingletonComponent
import okhttp3.OkHttpClient
import java.util.concurrent.TimeUnit
import javax.inject.Singleton

@Module
@InstallIn(SingletonComponent::class)
object AppModule {
    @Provides @Singleton
    fun settingsStore(@ApplicationContext context: android.content.Context): SettingsStore = PrefsSettingsStore(context)

    @Provides @Singleton
    fun secureStore(@ApplicationContext context: android.content.Context): SecureStore = SecureStore(context)

    @Provides @Singleton
    fun cookieStore(secureStore: SecureStore): CookieStore = PrefsCookieStore(secureStore)

    @Provides @Singleton
    fun cookieJar(store: CookieStore): PersistentCookieJar = PersistentCookieJar(store)

    @Provides @Singleton
    fun okHttp(cookieJar: PersistentCookieJar): OkHttpClient = OkHttpClient.Builder()
        .cookieJar(cookieJar)
        .connectTimeout(30, TimeUnit.SECONDS)
        .readTimeout(30, TimeUnit.SECONDS)
        .followRedirects(false)
        .followSslRedirects(false)
        .cache(null)
        .build()

    @Provides @Singleton
    fun apiClient(http: OkHttpClient, cookieJar: PersistentCookieJar): UpstreamApi =
        ApiClient(http, cookieJar, TestConfig.effectiveBaseUrl())
}
