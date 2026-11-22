import SwiftUI
import LeogotoPlayCore

/// 登录 / 注册页（本地账号实现，接入后端时替换 AuthServicing 即可）。
struct LoginView: View {
    @EnvironmentObject private var auth: AuthStore
    @Environment(\.dismiss) private var dismiss

    private enum Mode: String, CaseIterable, Identifiable {
        case login
        case register

        var id: String { rawValue }

        var title: String {
            switch self {
            case .login: return "登录"
            case .register: return "注册"
            }
        }
    }

    @State private var mode: Mode = .login
    @State private var nickname = ""
    @State private var email = ""
    @State private var password = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    header

                    Picker("模式", selection: $mode) {
                        ForEach(Mode.allCases) { item in
                            Text(item.title).tag(item)
                        }
                    }
                    .pickerStyle(.segmented)

                    VStack(spacing: 12) {
                        if mode == .register {
                            field(icon: "person", placeholder: "昵称（可选）", text: $nickname, isSecure: false)
                        }
                        field(icon: "envelope", placeholder: "邮箱", text: $email, isSecure: false)
                            .keyboardType(.emailAddress)
                            .textInputAutocapitalization(.never)
                        field(icon: "lock", placeholder: "密码（至少 6 位）", text: $password, isSecure: true)
                    }

                    if let message = auth.lastErrorMessage {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.circle.fill")
                            Text(message)
                        }
                        .font(.caption)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    Button(action: submit) {
                        HStack(spacing: 8) {
                            if auth.isBusy {
                                ProgressView().tint(.white)
                            }
                            Text(mode == .login ? "登录" : "创建账号")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(PrimaryButtonStyle(fillsWidth: true))
                    .disabled(auth.isBusy || !canSubmit)

                    Text("当前为本地演示账号体系：邮箱与密码保存在本机，登录态存储在 Keychain。接入后端时只需实现 AuthServicing。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(Theme.pagePadding)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle(mode.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
        .onChange(of: mode) { _ in
            auth.lastErrorMessage = nil
        }
    }

    private var header: some View {
        VStack(spacing: 8) {
            Image(systemName: "scissors")
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
                .background(Theme.accentGradient, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            Text("LeogotoPlay")
                .font(.title3.weight(.bold))
            Text(mode == .login ? "登录后继续你的剪辑与素材管理" : "注册一个本机账号，开始整理素材")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 8)
    }

    private func field(icon: String, placeholder: String, text: Binding<String>, isSecure: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            if isSecure {
                SecureField(placeholder, text: text)
            } else {
                TextField(placeholder, text: text)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
        )
    }

    private var canSubmit: Bool {
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedEmail.contains("@"), password.count >= 6 else { return false }
        return true
    }

    private func submit() {
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            switch mode {
            case .login:
                await auth.login(email: trimmedEmail, password: password)
            case .register:
                await auth.register(nickname: nickname, email: trimmedEmail, password: password)
            }
            if auth.isLoggedIn { dismiss() }
        }
    }
}
