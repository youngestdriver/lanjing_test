import SwiftUI

/// Practice quiz screen: header, stem, option rows, multi-select confirm,
/// answer-reveal banner (with remote formula images), next/finish. Pushed
/// inside the tab's NavigationStack, the page hides the tab bar (问题 4 —
/// full screen). Questions page left/right like the exam (需求 2): a
/// TabView(.page) whose selection binds to vm.jumpTo; each page is its own
/// ScrollView and reads that page index's answer (per-page rebuilds of the
/// web content are keyed via `.id(question.id)`).
struct PracticeQuizView: View {
    let vm: PracticeBankViewModel
    let category: String
    let subCategory: String

    @Environment(\.dismiss) private var dismiss
    @State private var showAnswerCard = false
    /// 跟手翻页的累计位移;悬停期间驱动页面平移,松手后归零(吸附动画)。
    @State private var dragOffset: CGFloat = 0
    /// 已物化(构建了 WebView/原生文本)的页索引。进入时只同步物化当前页,
    /// 其余页由 .task 后台按「距当前页最近」逐批补建——首屏不再为整个会话
    /// 的富文本一次性付费;跳转目标页总是立即物化且物化后永久保留(再次
    /// 跳转零加载)。未物化页与当前页并不重合(当前页永远立即建)。
    @State private var materializedPages: Set<Int> = []

    /// 尚未物化、离当前页最近的一页;nil = 全部物化完毕。当前页由 body
    /// 规则专属即时物化,不参与后台排队。
    private func nearestUnmaterialized(current: Int, count: Int) -> Int? {
        var best: Int?
        var bestDistance = Int.max
        for index in 0 ..< count
        where !materializedPages.contains(index) && index != current {
            let distance = abs(index - current)
            if distance < bestDistance {
                best = index
                bestDistance = distance
            }
        }
        return best
    }

    private var session: PracticeSession? { vm.session }
    private var question: BankQuestion? { vm.currentQuestion }

    var body: some View {
        Group {
            // 只有「归属本路由(大类+题型细分)」的会话才渲染内容:残留的上
            // 一场练习(上次系统返回不清理)在 resumeOrStart 完成前不能闪现
            // —— 与题型列表的 stale-subcategories 同源问题。
            if let session,
               session.category == category,
               session.subCategory == subCategory,
               !session.questions.isEmpty {
                if session.isFinished {
                    summaryCard(session)
                } else if let question {
                    quizContent(session, question)
                }
            } else if vm.phase != .ready {
                // Bank became unavailable mid-session — the bank view's phase
                // switch shows the failure screen instead.
                EmptyView()
            } else {
                loadingPlaceholder
            }
        }
        .navigationTitle("\(vm.session?.subCategory ?? subCategory)")
        .navigationBarTitleDisplayMode(.inline)
        // Tab 栏显隐由 PracticeBankView 按导航路径统一驱动
        // (path.isEmpty ? .automatic : .hidden)——见该文件注释。
        .task {
            // Resume a persisted run of this subcategory when it matches the
            // current bank (question-ID set check), otherwise start fresh.
            // System-back / swipe-back no longer clears anything — exiting
            // mid-run and re-entering continues where it left off (问题 3).
            await vm.resumeOrStart(category: category, subCategory: subCategory)
        }
        .task {
            // 后台预热:当前页已由 body 即时物化,这里逐批补建其余页
            // (每批一页、批间让出主线程,锚点跟随当前页)——首屏不为
            // 整个会话的富文本一次性付费,跳转目标页永远即时物化且保留。
            while !Task.isCancelled {
                let current = vm.session?.index ?? 0
                let count = vm.session?.questions.count ?? 0
                guard count > 0 else {
                    // resumeOrStart 尚未完成(或题库不可用)——让出后继续等。
                    await Task.yield()
                    continue
                }
                guard let target = nearestUnmaterialized(current: current, count: count) else { return }
                materializedPages.insert(target)
                await Task.yield()
            }
        }
        // 答题卡与考试同款:sheet 呈现(.medium/.large detents),不再用 overlay
        // (iOS 17 隐藏 tab bar 层级 sheet 的已知 bug 见 PracticeAnswerCardView 注释)。
        .sheet(isPresented: $showAnswerCard) {
            PracticeAnswerCardView(vm: vm)
        }
    }

    private var loadingPlaceholder: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("正在加载题目…")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func quizContent(_ session: PracticeSession, _ question: BankQuestion) -> some View {
        VStack(spacing: 0) {
            headerRow(session, question)
                .padding(.horizontal)
                .padding(.top, 8)
            if vm.resumedFromDisk && !session.isFinished {
                resumeBanner
                    .padding(.horizontal)
                    .padding(.top, 8)
            }
            // 全量预建 + 跟手分页:所有页常驻,任意跳转(含答题卡跳远)零
            // 加载、零骨架;手指拖动时当前页随位移平移、邻页同步显现,松手
            // 吸附——观感等同 TabView(.page) 的连续左右滑动。全量预建之所
            // 以可行:RichHTMLContent 只对含图块开 WebView(纯文本原生渲染),
            // 且图片以 data: URI 内联、无自定义 scheme handler,所有 WebView
            // 共享一个 WebContent 进程(自定义 scheme 正是之前进程风暴的根源)。
            GeometryReader { geo in
                let width = geo.size.width
                ZStack {
                    ForEach(session.questions.indices, id: \.self) { index in
                        if materializedPages.contains(index) || index == session.index {
                            questionPage(session, index)
                                .offset(x: pageOffset(index, session: session, width: width))
                                .opacity(index == session.index || (abs(index - session.index) == 1 && dragOffset != 0) ? 1 : 0)
                                .allowsHitTesting(index == session.index)
                                .accessibilityHidden(index != session.index)
                        } else {
                            // 未物化页:Color.clear 占位,不建任何富文本。
                            Color.clear
                                .accessibilityHidden(true)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                // simultaneousGesture:页内是横向禁用的垂直 ScrollView,但
                // UIScrollView 的 pan 识别器会抢先认领普通 .gesture(含 XCTest
                // 合成的 swipe,容器手势被 cancel);同时识别后由轴向判断分流
                // ——纵向交给页内滚动,横向才更新 dragOffset/X。onEnded 的
                // dragOffset != 0 守卫使纯粹纵向拖动成为 no-op。
                .simultaneousGesture(
                    DragGesture(minimumDistance: 12)
                        .onChanged { value in
                            // 纵向手势交给页内 ScrollView,不参与翻页
                            guard abs(value.translation.width) > abs(value.translation.height) else { return }
                            var offset = min(max(value.translation.width, -width), width)
                            // 首尾页阻尼,防止拖出界
                            if session.index == 0 && offset > 0 { offset *= 0.3 }
                            if session.index == session.questions.count - 1 && offset < 0 { offset *= 0.3 }
                            dragOffset = offset
                        }
                        .onEnded { value in
                            guard dragOffset != 0 else { return }
                            let edge = width * 0.25
                            let translation = abs(value.translation.width) > abs(value.translation.height)
                                ? value.translation.width
                                : 0
                            if translation < -edge || value.predictedEndTranslation.width < -edge {
                                withAnimation(.interpolatingSpring(stiffness: 300, damping: 32)) {
                                    dragOffset = 0
                                    vm.jumpTo(min(session.index + 1, session.questions.count - 1))
                                }
                            } else if translation > edge || value.predictedEndTranslation.width > edge {
                                withAnimation(.interpolatingSpring(stiffness: 300, damping: 32)) {
                                    dragOffset = 0
                                    vm.jumpTo(max(session.index - 1, 0))
                                }
                            } else {
                                withAnimation(.interpolatingSpring(stiffness: 300, damping: 32)) {
                                    dragOffset = 0
                                }
                            }
                        }
                )
            }
            .frame(maxHeight: .infinity)
            // Bottom bar mirrors the exam's AnswerCardView container (stats +
            // 答题卡, no 交卷 — 需求 1).
            PracticeStatsBarView(vm: vm) { showAnswerCard = true }
                .padding(.horizontal)
                .padding(.vertical, 10)
                .background(Color(.secondarySystemBackground))
        }
    }

    /// One-off notice that a persisted run was resumed (问题 3 的交互提示).
    /// consumeResumeNotice() dismisses it; the flag resets on every entry.
    private var resumeBanner: some View {
        HStack(spacing: 12) {
            Label("已恢复上次练习进度", systemImage: "arrow.counterclockwise")
            Spacer(minLength: 0)
            Button("知道了") { vm.consumeResumeNotice() }
                .font(.system(size: 13, weight: .bold))
        }
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(DS.blue)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(DS.blue.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: DS.radiusSM))
    }

    /// 页面偏移:当前页 0,第 index 页相对当前页的页距;拖动期间整体叠加
    /// dragOffset 实现跟手,配合 vm.jumpTo 完成吸附(答题卡跳转同样生效)。
    private func pageOffset(_ index: Int, session: PracticeSession, width: CGFloat) -> CGFloat {
        CGFloat(index - session.index) * width + dragOffset
    }

    /// 单页 = 一个可滚动题目页。页内答案取本页索引,而不是全局
    /// currentAnswer(相邻页渲染时全局 index 指向当前页,会错位)。
    private func questionPage(_ session: PracticeSession, _ index: Int) -> some View {
        let question = session.questions[index]
        let answer = index < session.answers.count
            ? session.answers[index]
            : PracticeSession.PracticeAnswer()
        let isLast = index + 1 >= session.questions.count
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let stem = question.stem, !stem.isEmpty {
                    RichHTMLContent(html: stem, fontSize: 15)
                        .id("\(question.id)-stem")
                        .accessibilityIdentifier("question-stem")
                        .padding(.bottom, 4)
                        .overlay(alignment: .bottom) { Divider() }
                }
                RichHTMLContent(html: question.question, fontSize: 17)
                    .id("\(question.id)-question")
                    .accessibilityIdentifier("question-text")
                options(for: question, answer: answer)
                if answer.revealed {
                    ExplainBannerView(
                        correct: answer.correct,
                        answerLabel: question.correctAnswers.joined(separator: "、"),
                        analysis: question.analysis
                    )
                    Button(isLast ? "完成" : "下一题") {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            vm.nextQuestion()
                        }
                    }
                    .buttonStyle(KeycapButtonStyle(color: DS.accent, radius: DS.radiusSM))
                    .frame(maxWidth: .infinity)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func headerRow(_ session: PracticeSession, _ question: BankQuestion) -> some View {
        HStack(spacing: 8) {
            Text("第 \(session.index + 1)/\(session.questions.count) 题")
                .font(.system(size: 13, weight: .heavy))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Color(.systemGray5))
                .clipShape(Capsule())
            if question.isMulti {
                Text("多选")
                    .font(.system(size: 13, weight: .heavy))
                    .foregroundStyle(DS.blue)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(DS.blue.opacity(0.12))
                    .clipShape(Capsule())
            }
            if !question.isGradable {
                Text("无答案")
                    .font(.system(size: 13, weight: .heavy))
                    .foregroundStyle(DS.orange)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(DS.orange.opacity(0.12))
                    .clipShape(Capsule())
            }
            Spacer()
        }
    }

    @ViewBuilder
    private func options(for question: BankQuestion, answer: PracticeSession.PracticeAnswer) -> some View {
        VStack(spacing: 12) {
            ForEach(question.letters, id: \.self) { letter in
                PracticeOptionRowView(
                    question: question,
                    letter: letter,
                    answer: answer,
                    onTap: { vm.tapOption(letter) }
                )
            }
        }
        if question.isMulti, !answer.revealed, !answer.selected.isEmpty {
            Button("提交") {
                vm.confirmSelection()
            }
            .buttonStyle(KeycapButtonStyle(color: DS.accent, radius: DS.radiusSM))
            .padding(.top, 4)
        }
    }

    private func summaryCard(_ session: PracticeSession) -> some View {
        VStack(spacing: 16) {
            Image(systemName: session.wrongCount == 0 ? "checkmark.seal.fill" : "flag.checkered")
                .font(.system(size: 44))
                .foregroundStyle(session.wrongCount == 0 ? DS.accent : DS.orange)
            Text("练习完成")
                .font(.system(size: 20, weight: .heavy))
            VStack(spacing: 6) {
                Text("答对 \(session.rightCount) 题")
                Text("答错 \(session.wrongCount) 题")
                Text("共 \(session.questions.count) 题")
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 15))
            Button("返回题型列表") {
                vm.endSession()
                dismiss()
            }
            .buttonStyle(KeycapButtonStyle(color: DS.accent, radius: DS.radiusSM))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
