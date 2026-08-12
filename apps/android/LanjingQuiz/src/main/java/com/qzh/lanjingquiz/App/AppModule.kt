package com.qzh.lanjingquiz.App

import com.qzh.lanjingquiz.Data.BankStorage
import com.qzh.lanjingquiz.Data.FileBankStorage
import com.qzh.lanjingquiz.Data.FilePracticeProgressStore
import com.qzh.lanjingquiz.Data.FilePracticeSessionStore
import com.qzh.lanjingquiz.Data.PracticeProgressStore
import com.qzh.lanjingquiz.Data.PracticeSessionStore
import com.qzh.lanjingquiz.Data.PrefsSettingsStore
import com.qzh.lanjingquiz.Data.SecureStore
import com.qzh.lanjingquiz.Data.SettingsStore
import com.qzh.lanjingquiz.Domain.Crawler
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

    // 惰性解析:Hilt 在 attachBaseContext 期构造单例(早于 onCreate 读取测试 extra),
    // base URL 必须按请求解析(TestConfig 只在测试进程写入;生产恒为 DEFAULT_BASE_URL)。
    @Provides @Singleton
    fun apiClient(http: OkHttpClient, cookieJar: PersistentCookieJar): UpstreamApi =
        ApiClient(http, cookieJar) { TestConfig.effectiveBaseUrl() }

    // ---- T5 练习模块:文件存储 + 爬取器(全部 context 派生单例)----
    @Provides @Singleton
    fun bankStorage(@ApplicationContext context: android.content.Context): BankStorage =
        FileBankStorage(context)

    @Provides @Singleton
    fun practiceSessionStore(@ApplicationContext context: android.content.Context): PracticeSessionStore =
        FilePracticeSessionStore(context)

    @Provides @Singleton
    fun practiceProgressStore(@ApplicationContext context: android.content.Context): PracticeProgressStore =
        FilePracticeProgressStore(context)

    @Provides @Singleton
    fun crawler(api: UpstreamApi, storage: BankStorage): Crawler = Crawler(api, storage)
}
