package com.qzh.lanjingquiz.UI.ExamList

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.qzh.lanjingquiz.App.AppState
import com.qzh.lanjingquiz.App.Route
import com.qzh.lanjingquiz.Domain.ExamHtmlParser
import com.qzh.lanjingquiz.Network.ApiException
import com.qzh.lanjingquiz.Network.ExamDto
import com.qzh.lanjingquiz.Network.UpstreamApi
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import javax.inject.Inject

/** 考试列表分组(过滤/分组/排序规则 spec §四)。 */
data class ExamGroup(val styleName: String, val exams: List<ExamDto>)

/**
 * 考试列表 —— iOS ExamListViewModel.swift 移植:
 * 过滤卷名含"常识判断"、按 style 分组、"机考题库"组排前、组内按 style 名排序;
 * wfs==1 显示 "新试卷" 走新卷流程,否则 "继续考试";放弃考试后抑制陈旧记录(按 id+wfs 精确匹配,
 * 服务端返回新 wfs 时解除)。
 */
@HiltViewModel
class ExamListViewModel @Inject constructor(
    private val api: UpstreamApi,
    private val appState: AppState,
) : ViewModel() {

    sealed interface Phase {
        data object Loading : Phase
        data object Ready : Phase
        data object Empty : Phase
        data class Failed(val msg: String) : Phase
    }

    private val _phase = MutableStateFlow<Phase>(Phase.Loading)
    val phase: StateFlow<Phase> = _phase.asStateFlow()

    private val _groups = MutableStateFlow<List<ExamGroup>>(emptyList())
    val groups: StateFlow<List<ExamGroup>> = _groups.asStateFlow()

    /** 最近一次服务端列表;放弃后的抑制在 apply 中执行。 */
    private var lastExams: List<ExamDto> = emptyList()
    /** id → wfs:本地刚结束的陈旧状态;服务端仍返回相同 id+wfs 时继续抑制,变化则解除。 */
    private val suppressedExamStates = mutableMapOf<Int, Int>()

    fun refresh() {
        viewModelScope.launch {
            _phase.value = Phase.Loading
            try {
                val list = api.examList()
                lastExams = list.exams
                apply(list.exams)
                _phase.value = if (list.exams.isEmpty()) Phase.Empty else Phase.Ready
            } catch (e: ApiException) {
                if (e.code == ApiException.SESSION_EXPIRED || e.code == ApiException.NOT_LOGGED_IN) {
                    appState.handleSessionExpiry()
                } else if (_groups.value.isEmpty()) {
                    _phase.value = Phase.Failed(e.message ?: "获取考试列表失败")
                }
                // 已有数据:静默保留旧列表(iOS 行为:errorMessage 仅在 exams 为空时展示)
            }
        }
    }

    /** 进入考试:直接路由(iOS 同;进入动作在 QuizViewModel.start 完成)。 */
    fun enter(exam: ExamDto) {
        appState.navigateTo(Route.Quiz(exam))
    }

    /**
     * 放弃考试(UI 层确认后调用):best-effort 交卷 → 立即抑制陈旧记录 → 同步列表
     * (上游列表可能滞后于 exam_ending,重试一次让"新卷"状态出现而不暴露旧作答)。
     */
    fun abandon(exam: ExamDto) {
        viewModelScope.launch {
            try {
                val html = api.examStartHtml(exam.id.toString())
                val page = ExamHtmlParser.parse(html, fallbackExamInfoId = exam.id.toString())
                val resultsId = page.examResultsId.ifEmpty {
                    throw ApiException(ApiException.UPSTREAM, "无法获取考试记录 ID")
                }
                api.submitExam(page.examInfoId, resultsId)
                suppressedExamStates[exam.id] = exam.wfs ?: 0
                apply(lastExams)
                refresh()
                delay(1000)
                refresh()
            } catch (e: ApiException) {
                if (e.code == ApiException.SESSION_EXPIRED || e.code == ApiException.NOT_LOGGED_IN) {
                    appState.handleSessionExpiry()
                } else {
                    appState.showNotice("放弃失败：${e.message}")
                }
            }
        }
    }

    /** 过滤 + 分组(iOS renderExamList):"常识判断"剔除、"机考题库"组排前、按 style 名排序。 */
    companion object {
        fun groupExams(exams: List<ExamDto>): List<ExamGroup> {
            val visible = exams.filter { !it.name.contains("常识判断") }
            val byStyle = visible.groupBy { it.styleName ?: "unknown" }
            return byStyle.keys.sortedWith(compareBy({ !it.contains("机考题库") }, { it }))
                .map { ExamGroup(it, byStyle[it] ?: emptyList()) }
        }
    }

    private fun apply(freshExams: List<ExamDto>) {
        // 抑制仅在服务端仍返回完全相同的旧状态时保留;同 id 换 wfs = 新状态,解除抑制
        suppressedExamStates.entries.removeAll { (id, wfs) ->
            freshExams.none { it.id == id && it.wfs == wfs }
        }
        val visible = freshExams.filter { exam -> suppressedExamStates[exam.id] != exam.wfs }
        _groups.value = groupExams(visible)
    }
}
