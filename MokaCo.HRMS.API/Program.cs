using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Text;
using Microsoft.AspNetCore.Authentication.JwtBearer;
using Microsoft.AspNetCore.Hosting.Server;
using Microsoft.AspNetCore.Hosting.Server.Features;
using Microsoft.AspNetCore.Authorization;
using Microsoft.IdentityModel.Tokens;
using MokaCo.HRMS.Api.Auth;
using MokaCo.HRMS.Api.Errors;
using MokaCo.HRMS.Repository.Common;
using MokaCo.HRMS.Repository.Security;
using MokaCo.HRMS.Repository.Core;
using MokaCo.HRMS.Repository.HR;
using MokaCo.HRMS.Repository.Attendance;
using MokaCo.HRMS.Repository.Report;
using MokaCo.HRMS.Repository.Workflow;
using MokaCo.HRMS.Repository.Payroll;
using MokaCo.HRMS.Repository.Booking;
using MokaCo.HRMS.Services.Auth;
using MokaCo.HRMS.Services.Security;
using MokaCo.HRMS.Services.Core;
using MokaCo.HRMS.Services.HR;
using MokaCo.HRMS.Services.Attendance;
using MokaCo.HRMS.Services.Report;
using MokaCo.HRMS.Services.Workflow;
using MokaCo.HRMS.Services.Payroll;
using MokaCo.HRMS.Services.Booking;
using MokaCo.HRMS.Services.Booking.Payments;
using MokaCo.HRMS.Api.Hubs;
using MokaCo.HRMS.Api.Jobs;
using MokaCo.HRMS.Api.Controllers;
using MokaCo.HRMS.Api.PublicBooking;
using Microsoft.AspNetCore.Cors.Infrastructure;
using Microsoft.AspNetCore.Mvc;
using System.Threading.RateLimiting;
using Quartz;
using Scalar.AspNetCore;

// QUESTPDF'S LICENCE IS DECLARED IN CODE, and the library throws on first render without it. The
// Community tier is the free one and it is what this deployment qualifies for; stating it here means
// the first request PDF ever generated is not the thing that discovers the omission.
QuestPDF.Settings.License = QuestPDF.Infrastructure.LicenseType.Community;

var builder = WebApplication.CreateBuilder(args);

// --- Configuration ---
// SECRETS LIVE IN appsettings.Local.json, WHICH GIT NEVER SEES. The tracked appsettings.json carries a
// connection string with no password in it (Windows authentication); the machine's real one — SQL
// login and password — goes in appsettings.Local.json beside it (gitignored; copy
// appsettings.Local.example.json). Added LAST among the files so it wins over appsettings.json and
// appsettings.{Environment}.json, and BEFORE re-adding the environment variables and command line so
// a deployment that sets ConnectionStrings__MokaCo in its environment still has the final word.
builder.Configuration
    .AddJsonFile("appsettings.Local.json", optional: true, reloadOnChange: false)
    .AddEnvironmentVariables()
    .AddCommandLine(args);

var connectionString = builder.Configuration.GetConnectionString("MokaCo")
    ?? throw new InvalidOperationException("Missing connection string 'MokaCo'.");

var jwtOptions = builder.Configuration.GetSection("Jwt").Get<JwtOptions>()
    ?? throw new InvalidOperationException("Missing 'Jwt' configuration.");

// ONLINE DEPOSITS (MPGS). The gateway's credentials and the two public origins come from the
// environment — /etc/mokaco/api.env in production, the gitignored appsettings.Local.json in
// development — never from a tracked file. FAIL FAST: a missing value stops the start here, naming
// the key (never the value). See MpgsOptions for the 3-D Secure bypass rule (TEST profile + flag).
var mpgsOptions = MpgsOptions.FromSettings(key => builder.Configuration[key]);
var depositTiming = builder.Configuration.GetSection(OnlineDepositOptions.Section).Get<OnlineDepositOptions>() ?? new OnlineDepositOptions();
depositTiming.Validate();

// --- DI: infrastructure ---
builder.Services.AddSingleton<IDbConnectionFactory>(new SqlConnectionFactory(connectionString));
builder.Services.AddSingleton(jwtOptions);

// --- DI: repositories (Security) ---
builder.Services.AddScoped<IUserRepository, UserRepository>();
builder.Services.AddScoped<IUserSignatureRepository, UserSignatureRepository>();
builder.Services.AddScoped<IRoleRepository, RoleRepository>();
builder.Services.AddScoped<IPermissionRepository, PermissionRepository>();
builder.Services.AddScoped<IRefreshTokenRepository, RefreshTokenRepository>();

// --- DI: repositories (Core) ---
builder.Services.AddScoped<ICurrencyRepository, CurrencyRepository>();
builder.Services.AddScoped<IHolidayRepository, HolidayRepository>();
builder.Services.AddScoped<IExchangeRateRepository, ExchangeRateRepository>();
builder.Services.AddScoped<IDashboardRepository, DashboardRepository>();

// --- DI: repositories (HR) ---
builder.Services.AddScoped<IBranchRepository, BranchRepository>();
builder.Services.AddScoped<IDepartmentRepository, DepartmentRepository>();
builder.Services.AddScoped<IPositionRepository, PositionRepository>();
builder.Services.AddScoped<IComponentTypeRepository, ComponentTypeRepository>();
builder.Services.AddScoped<IEmployeeRepository, EmployeeRepository>();
builder.Services.AddScoped<ILeaveTypeRepository, LeaveTypeRepository>();
builder.Services.AddScoped<ISalaryComponentRepository, SalaryComponentRepository>();
builder.Services.AddScoped<IDocumentRepository, DocumentRepository>();
builder.Services.AddScoped<ILeaveLedgerRepository, LeaveLedgerRepository>();
builder.Services.AddScoped<ILeaveYearRepository, LeaveYearRepository>();
builder.Services.AddScoped<IPayrollTierRepository, PayrollTierRepository>();
builder.Services.AddScoped<IApprovalTierRepository, ApprovalTierRepository>();

// --- DI: repositories (Attendance) ---
builder.Services.AddScoped<ISettingRepository, SettingRepository>();
builder.Services.AddScoped<IEmailRepository, EmailRepository>();
builder.Services.AddScoped<ISystemRepository, SystemRepository>();
builder.Services.AddScoped<IDeviceRepository, DeviceRepository>();
builder.Services.AddScoped<IShiftRepository, ShiftRepository>();
builder.Services.AddScoped<IRosterRepository, RosterRepository>();
builder.Services.AddScoped<IIngestionRepository, IngestionRepository>();
builder.Services.AddScoped<IAttendanceRepository, AttendanceRepository>();
builder.Services.AddScoped<ICorrectionRepository, CorrectionRepository>();

// --- DI: repositories (Report) ---
builder.Services.AddScoped<IReportRepository, ReportRepository>();

// --- DI: repositories (Workflow) ---
builder.Services.AddScoped<IDefinitionRepository, DefinitionRepository>();
builder.Services.AddScoped<IRequestRepository, RequestRepository>();
builder.Services.AddScoped<IAttachmentRepository, AttachmentRepository>();
builder.Services.AddScoped<IExitPermissionRepository, ExitPermissionRepository>();
builder.Services.AddScoped<ILeaveRequestRepository, LeaveRequestRepository>();
builder.Services.AddScoped<ITipDistributionRepository, TipDistributionRepository>();
builder.Services.AddScoped<IRosterApprovalRepository, RosterApprovalRepository>();
builder.Services.AddScoped<IShiftSwapRepository, ShiftSwapRepository>();
builder.Services.AddScoped<IOvertimeRepository, OvertimeRepository>();
builder.Services.AddScoped<IExpenseRepository, ExpenseRepository>();
builder.Services.AddScoped<IAvailabilityRepository, AvailabilityRepository>();
builder.Services.AddScoped<IOnboardingRepository, OnboardingRepository>();
builder.Services.AddScoped<ISeparationRepository, SeparationRepository>();
builder.Services.AddScoped<IPayrollAdjustmentRepository, PayrollAdjustmentRepository>();
builder.Services.AddScoped<ISalaryAdvanceRepository, SalaryAdvanceRepository>();
builder.Services.AddScoped<IWorkflowSupportRepository, WorkflowSupportRepository>();

// --- DI: repositories (Payroll) ---
builder.Services.AddScoped<IPayrollRepository, PayrollRepository>();

// --- DI: repositories (Booking) ---
builder.Services.AddScoped<IRoomRepository, RoomRepository>();
builder.Services.AddScoped<IBookingRepository, BookingRepository>();
builder.Services.AddScoped<IOnlineDepositRepository, OnlineDepositRepository>();

// --- DI: services (Security) ---
builder.Services.AddSingleton<IPasswordHasher, Argon2PasswordHasher>();
builder.Services.AddSingleton<IJwtTokenService, JwtTokenService>();
builder.Services.AddScoped<IAuthService, AuthService>();
builder.Services.AddScoped<IUserService, UserService>();
builder.Services.AddScoped<IUserSignatureService, UserSignatureService>();

// --- DI: services (Core) ---
builder.Services.AddScoped<ICurrencyService, CurrencyService>();
builder.Services.AddScoped<IHolidayService, HolidayService>();
builder.Services.AddScoped<IExchangeRateService, ExchangeRateService>();
builder.Services.AddScoped<IDashboardService, DashboardService>();
// Manual "email the employee" only. The WORKER does not resolve this — a background service has no
// caller to translate refusals for, so it takes IEmailRepository directly.
builder.Services.AddScoped<IEmailService, EmailService>();

// The WhatsApp Cloud API call. A FACTORY rather than a new HttpClient per send: the worker runs
// every minute for the life of the process, and a fresh HttpClient each time is the textbook way to
// exhaust the socket pool.
builder.Services.AddHttpClient();

// --- DI: services (HR) ---
builder.Services.AddScoped<IBranchService, BranchService>();
builder.Services.AddScoped<IDepartmentService, DepartmentService>();
builder.Services.AddScoped<IPositionService, PositionService>();
builder.Services.AddScoped<IComponentTypeService, ComponentTypeService>();
builder.Services.AddScoped<IEmployeeService, EmployeeService>();
builder.Services.AddScoped<ILeaveTypeService, LeaveTypeService>();
builder.Services.AddScoped<ISalaryComponentService, SalaryComponentService>();
builder.Services.AddScoped<IDocumentService, DocumentService>();
builder.Services.AddScoped<ILeaveLedgerService, LeaveLedgerService>();
builder.Services.AddScoped<ILeaveYearService, LeaveYearService>();
builder.Services.AddScoped<IPayrollTierService, PayrollTierService>();
builder.Services.AddScoped<IApprovalTierService, ApprovalTierService>();

// --- DI: services (Attendance) ---
builder.Services.AddScoped<ISettingService, SettingService>();
builder.Services.AddScoped<IDeviceService, DeviceService>();
builder.Services.AddScoped<IShiftService, ShiftService>();
builder.Services.AddScoped<IRosterService, RosterService>();
builder.Services.AddScoped<IImportService, ImportService>();
builder.Services.AddScoped<IAttendanceService, AttendanceService>();
builder.Services.AddScoped<ICorrectionService, CorrectionService>();

// Machine pull: the server calling the terminal, as opposed to the iclock endpoint where it calls us.
// The LOCKS are a singleton and must stay one — they are what stops the timer and the "Pull now"
// button opening two sessions to the same machine, and a scoped registry would hand each caller its
// own semaphore and therefore lock nothing at all.
builder.Services.AddSingleton<DevicePullLocks>();
builder.Services.AddScoped<IMachinePullService, MachinePullService>();
builder.Services.AddHostedService<MachinePullWorker>();

// Outgoing mail: the OUTBOX is drained by a worker, never sent inline from the act that caused it.
// Closing a request must commit whether or not a mail server is reachable, so the closing writes a
// row and this turns rows into mail a minute later. No SmtpHost configured = it quietly does nothing.
builder.Services.AddHostedService<EmailWorker>();

// --- DI: services (Report) ---
builder.Services.AddScoped<IReportService, ReportService>();

// --- DI: services (Workflow) ---
builder.Services.AddScoped<IDefinitionService, DefinitionService>();
builder.Services.AddScoped<IRequestService, RequestService>();
builder.Services.AddScoped<IAttachmentService, AttachmentService>();
builder.Services.AddScoped<IExitPermissionService, ExitPermissionService>();
builder.Services.AddScoped<ILeaveRequestService, LeaveRequestService>();
builder.Services.AddScoped<IDecisionSignatureService, DecisionSignatureService>();
builder.Services.AddScoped<ITipDistributionService, TipDistributionService>();
builder.Services.AddScoped<IRosterApprovalService, RosterApprovalService>();
builder.Services.AddScoped<IShiftSwapService, ShiftSwapService>();
builder.Services.AddScoped<IOvertimeService, OvertimeService>();
builder.Services.AddScoped<IExpenseService, ExpenseService>();
builder.Services.AddScoped<IAvailabilityService, AvailabilityService>();
builder.Services.AddScoped<IOnboardingService, OnboardingService>();
builder.Services.AddScoped<ISeparationService, SeparationService>();
builder.Services.AddScoped<IPayrollAdjustmentService, PayrollAdjustmentService>();

// The request PDF that goes out attached to the closing email. Scoped, because it reads through the
// request repository — the worker resolves it inside its own per-cycle scope.
builder.Services.AddScoped<IRequestPdfBuilder, RequestPdfBuilder>();
builder.Services.AddScoped<ISalaryAdvanceService, SalaryAdvanceService>();
builder.Services.AddScoped<IWorkflowSupportService, WorkflowSupportService>();

// --- DI: services (Payroll) ---
builder.Services.AddScoped<IPayrollService, PayrollService>();

// --- DI: services (Booking) ---
builder.Services.AddScoped<IRoomService, RoomService>();
builder.Services.AddScoped<IBookingService, BookingService>();

// Online deposits. The gateway client is a TYPED HttpClient (pooled handlers, no socket exhaustion);
// its own calls carry short per-request timeouts, the client-wide one is only a backstop. Logged
// headers are redacted wholesale: the Authorization header carries the merchant password.
builder.Services.AddSingleton(mpgsOptions);
builder.Services.AddSingleton(depositTiming);
builder.Services.AddSingleton(TimeProvider.System);
builder.Services.AddHttpClient<IMpgsClient, MpgsClient>(client => client.Timeout = TimeSpan.FromSeconds(60))
    .RedactLoggedHeaders(_ => true);
builder.Services.AddScoped<IOnlineDepositService, OnlineDepositService>();

// --- Scheduled jobs (Quartz.NET, in-memory RAMJobStore — no DB job store) ---
builder.Services.AddQuartz(q =>
{
    /* NO MONTHLY LEAVE ACCRUAL JOB. Entitlement is granted by the YEARLY OPENING
       (POST /api/leave/year-open → hr.usp_LeaveYear_Open), which is deliberately manual: it is a
       once-a-year act somebody decides to take, and its per-type summary is the point of taking it.
       The old monthly job read hr.LEAVE_TYPE.AccrualPerMonth, a column that no longer exists. */

    // Attendance: process punches, mark absentees, reclassify approved leave.
    // The store is in-memory, so a run missed while the API was down is LOST, not caught up —
    // which is why /api/attendance/process and /mark-absentees are also exposed manually.
    var nightlyAttendanceJobKey = new JobKey("NightlyAttendanceJob");
    q.AddJob<NightlyAttendanceJob>(opts => opts.WithIdentity(nightlyAttendanceJobKey));
    q.AddTrigger(t => t
        .ForJob(nightlyAttendanceJobKey)
        .WithIdentity("NightlyAttendanceTrigger")
        // seconds-first cron: 01:00 every day
        .WithCronSchedule("0 0 1 * * ?"));

    // Bookings: every five minutes, cancel website payment holds whose clock ran out unpaid
    // (booking.usp_Booking_ExpireHolds). Tidying, not enforcement — every availability query
    // already excludes an expired hold. See BookingHoldExpiryJob.
    var bookingHoldExpiryJobKey = new JobKey("BookingHoldExpiryJob");
    q.AddJob<BookingHoldExpiryJob>(opts => opts.WithIdentity(bookingHoldExpiryJobKey));
    q.AddTrigger(t => t
        .ForJob(bookingHoldExpiryJobKey)
        .WithIdentity("BookingHoldExpiryTrigger")
        .WithCronSchedule("0 0/5 * * * ?"));

    // Bookings: every OnlineDeposits:ReconcileEveryMinutes, settle the online deposits whose return
    // trip never arrived — ask the gateway, then confirm, release or alert staff through the same
    // path as /verify. The sweep above leaves every booking whose payment was opened to this job.
    var bookingPaymentReconcileJobKey = new JobKey("BookingPaymentReconcileJob");
    q.AddJob<BookingPaymentReconcileJob>(opts => opts.WithIdentity(bookingPaymentReconcileJobKey));
    q.AddTrigger(t => t
        .ForJob(bookingPaymentReconcileJobKey)
        .WithIdentity("BookingPaymentReconcileTrigger")
        .StartAt(DateBuilder.FutureDate(1, IntervalUnit.Minute))
        .WithSimpleSchedule(s => s.WithIntervalInMinutes(depositTiming.ReconcileEveryMinutes).RepeatForever()));
});
builder.Services.AddQuartzHostedService(opts => opts.WaitForJobsToComplete = true);

// --- Authentication (JWT) ---
builder.Services.AddAuthentication(JwtBearerDefaults.AuthenticationScheme)
    .AddJwtBearer(options =>
    {
        options.TokenValidationParameters = new TokenValidationParameters
        {
            ValidateIssuer = true,
            ValidateAudience = true,
            ValidateLifetime = true,
            ValidateIssuerSigningKey = true,
            ValidIssuer = jwtOptions.Issuer,
            ValidAudience = jwtOptions.Audience,
            IssuerSigningKey = new SymmetricSecurityKey(Encoding.UTF8.GetBytes(jwtOptions.SecretKey)),
            ClockSkew = TimeSpan.FromSeconds(30)
        };

        // THE HUB'S TOKEN ARRIVES IN THE QUERY STRING, and only the hub's.
        //
        // WebSockets cannot carry custom headers from a browser — the WebSocket API has no way to
        // set Authorization — so SignalR's standard pattern is ?access_token=. That is a real
        // trade: query strings land in server logs and browser history in a way headers do not.
        // It is scoped as tightly as possible: the token is read ONLY for the hub path, so every
        // ordinary API call keeps using the Authorization header and gains no new exposure.
        options.Events = new JwtBearerEvents
        {
            OnMessageReceived = context =>
            {
                var accessToken = context.Request.Query["access_token"];
                var path = context.HttpContext.Request.Path;
                // /hubs/booking too: staff connect to it with their token. A guest sends none, and the
                // hub is [AllowAnonymous], so an absent token there is not a failure.
                if (!string.IsNullOrEmpty(accessToken)
                    && (path.StartsWithSegments("/hubs/live") || path.StartsWithSegments("/hubs/booking")))
                    context.Token = accessToken;

                return Task.CompletedTask;
            }
        };
    });

// --- Authorization (permission policies) ---
//
// THE FALLBACK IS THE DEFAULT ANSWER. Without it, an endpoint carrying no [Authorize] and no
// [HasPermission] is simply OPEN — protection is opt-in, and forgetting the attribute on one new
// action is a silent hole rather than a compile error. With it, authentication is the floor and an
// endpoint has to say [AllowAnonymous] out loud to be public.
//
// It applies only where NOTHING else is specified, so every existing [Authorize] and permission
// policy is untouched. Four things are deliberately public and now say so:
//   - AuthController login + refresh ([AllowAnonymous]) — you cannot hold a token before logging in;
//   - IclockController ([AllowAnonymous] on the class) — the fingerprint terminals speak a fixed
//     ZKTeco protocol and cannot send a bearer token; they are gated by serial + rate limiter;
//   - AttendanceIngestion punch ([AllowAnonymous]) — [DeviceApiKey] is an action FILTER, not an
//     authentication scheme, so the fallback would demand a JWT the device does not have;
//   - the Development-only OpenAPI/Scalar endpoints.
builder.Services.AddSingleton<IAuthorizationPolicyProvider, PermissionPolicyProvider>();
builder.Services.AddAuthorization(options =>
{
    options.FallbackPolicy = new AuthorizationPolicyBuilder()
        .RequireAuthenticatedUser()
        .Build();
});

// --- Rate limiting: the fingerprint terminals' push endpoints only ---
//
// Scoped to /iclock/* by the [EnableRateLimiting] attribute on IclockController, because that is
// the one part of the API that is not behind a JWT: it is reachable by anyone who can guess a
// registered serial, and the serial is printed on the back of the machine. Everything else in the
// API is protected by having to log in first, and a limiter there would only ever punish real users.
//
// PARTITIONED BY SERIAL, so one terminal (or one leaked serial) cannot starve the others. Falls
// back to the remote IP when there is no SN — a caller that has not even said who it claims to be
// still must not get an unlimited number of guesses.
//
// The ceiling is deliberately generous. A real terminal with Realtime=1 sends one small request per
// punch plus a command poll every few seconds; a busy door at shift change might produce a few
// dozen requests in a minute, and a device flushing a backlog after an outage produces a burst.
// This is sized to be invisible to all of that and to still cap a flood.
builder.Services.AddRateLimiter(options =>
{
    // 429 is not in a fingerprint terminal's vocabulary. 503 is a "try later" it already handles by
    // keeping the batch and retrying — which is exactly what we want it to do, since a throttled
    // punch must not be treated by the device as delivered.
    options.RejectionStatusCode = StatusCodes.Status503ServiceUnavailable;

    // ...BUT 503 IS THE TERMINALS' ANSWER, NOT THE WEB'S. RejectionStatusCode is a single global
    // value, and the public booking endpoints are talked to by browsers, where "try later" is 429
    // and 503 reads as "the site is down". This runs after the middleware has applied the default,
    // so the assignment wins; the terminals keep the 503 their retry logic already understands.
    options.OnRejected = (context, _) =>
    {
        if (context.HttpContext.Request.Path.StartsWithSegments("/api/public/booking"))
            context.HttpContext.Response.StatusCode = StatusCodes.Status429TooManyRequests;

        return ValueTask.CompletedTask;
    };

    // --- The public booking endpoints: per IP, and read and write counted SEPARATELY ---
    //
    // Two policies rather than one because the two are abused differently. Browsing a month of a
    // calendar is a dozen GETs in a few seconds and must stay comfortable; POSTing a booking is a
    // thing a human does once, so five in a minute is already a script. Separate policies also mean
    // a visitor who has hit the read limit can still complete the booking they came for.
    //
    // PARTITIONED BY REMOTE IP, which is the only identity an anonymous caller has. NOTE FOR
    // DEPLOYMENT: behind a reverse proxy (IIS/nginx) every request arrives from the proxy's address
    // and the whole internet shares one partition. If this is fronted, add ForwardedHeaders
    // middleware — otherwise the limit is global rather than per visitor.
    static string ClientPartition(HttpContext context)
        => context.Connection.RemoteIpAddress?.ToString() ?? "unknown";

    options.AddPolicy(PublicBookingController.ReadRateLimitPolicy, context =>
        RateLimitPartition.GetFixedWindowLimiter(ClientPartition(context), _ => new FixedWindowRateLimiterOptions
        {
            PermitLimit = 30,
            Window = TimeSpan.FromMinutes(1),
            QueueLimit = 0                     // refuse now; a queued page load is a hung page load
        }));

    options.AddPolicy(PublicBookingController.WriteRateLimitPolicy, context =>
        RateLimitPartition.GetFixedWindowLimiter(ClientPartition(context), _ => new FixedWindowRateLimiterOptions
        {
            PermitLimit = 5,
            Window = TimeSpan.FromMinutes(1),
            QueueLimit = 0
        }));

    options.AddPolicy(IclockController.RateLimitPolicy, context =>
    {
        var serial = context.Request.Query["SN"].ToString();
        var partition = string.IsNullOrWhiteSpace(serial)
            ? $"ip:{context.Connection.RemoteIpAddress}"
            : $"sn:{serial}";

        return RateLimitPartition.GetFixedWindowLimiter(partition, _ => new FixedWindowRateLimiterOptions
        {
            PermitLimit = 240,                     // ~4/second sustained, per terminal
            Window = TimeSpan.FromMinutes(1),
            QueueLimit = 0                         // refuse immediately; the device's own retry IS the queue
        });
    });
});

// --- CORS for the React front end (adjust origin) ---
const string CorsPolicy = PublicBookingCorsPolicyProvider.StaffFrontPolicy;   // "MokaCoFront"

// The PUBLIC BOOKING ORIGINS come from core.SETTING BookingCorsOrigins, NOT from appsettings.json.
// PublicBookingGate reads that row (with BookingWebsiteEnabled and BookingApiKey) once a minute, and
// PublicBookingCorsPolicyProvider builds the "PublicBooking" policy from it per request — preflight
// included — so an origin added on the Settings page works within a minute and without a restart.
// The same reading is what PublicBookingAccessAttribute judges a caller by, so the CORS answer and
// the access answer cannot disagree. An empty list matches no origin: same-origin only.
builder.Services.AddSingleton<PublicBookingGate>();
builder.Services.AddSingleton<IPublicBookingGate>(sp => sp.GetRequiredService<PublicBookingGate>());

builder.Services.AddCors(o =>
{
    o.AddPolicy(CorsPolicy, p =>
        p.WithOrigins("http://localhost:5173")   // Vite dev server; change as needed
         .AllowAnyHeader()
         .AllowAnyMethod()
         // Required by SignalR: its JS client sets withCredentials on the negotiate request, and a
         // response without Access-Control-Allow-Credentials fails CORS before the socket is ever
         // opened. Legal here only because the origin is named explicitly — the browser refuses this
         // combined with a wildcard origin, which is the rule that keeps it safe.
         .AllowCredentials());

    // "PublicBooking" is NOT registered here: the provider below answers for it dynamically.
});

// Registered AFTER AddCors on purpose — AddCors TryAdds the framework provider, and the last
// registration is the one the container resolves. Every policy other than "PublicBooking" is still
// answered by the framework's own provider (the class wraps it).
builder.Services.AddSingleton<ICorsPolicyProvider, PublicBookingCorsPolicyProvider>();

// --- Live updates (SignalR): signals only, never data ---
builder.Services.AddSignalR();
builder.Services.AddSingleton<ILiveNotifier, LiveNotifier>();
// Live BOOKING updates (BookingHub): scoped because it re-reads the booking through the repository.
builder.Services.AddScoped<IBookingLivePublisher, BookingLivePublisher>();

builder.Services.AddControllers();

// EVERY UNHANDLED EXCEPTION LEAVES AS { error, traceId } (BUG-03) — a constraint violation as a 4xx
// sentence, a bug as a 500 that carries a reference and nothing else. See ApiErrorMap for the table.
builder.Services.AddExceptionHandler<ApiExceptionHandler>();

// THE PUBLIC BOOKING API ANSWERS EVERY REFUSAL AS { error, code }, model-binding failures included.
// [ApiController] would otherwise answer a malformed body with a ProblemDetails document the website
// cannot read a sentence out of. Scoped to that path: every other controller keeps the default.
builder.Services.Configure<ApiBehaviorOptions>(options =>
{
    var frameworkDefault = options.InvalidModelStateResponseFactory;
    options.InvalidModelStateResponseFactory = context =>
    {
        if (!context.HttpContext.Request.Path.StartsWithSegments("/api/public/booking"))
            return frameworkDefault(context);

        var first = context.ModelState
            .Where(entry => entry.Value?.Errors.Count > 0)
            .Select(entry => new { Field = entry.Key, Message = entry.Value!.Errors[0].ErrorMessage })
            .FirstOrDefault();

        // The binder's own messages name .NET types and JSON paths; a guest gets one sentence.
        return new BadRequestObjectResult(new
        {
            error = "Please check the details and try again.",
            code = BookingRefusals.InvalidInput,
            field = string.IsNullOrEmpty(first?.Field) ? null : char.ToLowerInvariant(first.Field[0]) + first.Field[1..],
            timeZone = BeirutTime.IanaId,
        });
    };
});

builder.Services.AddOpenApi();

var app = builder.Build();

// Everything about the gateway but the password, once, so a wrong host or profile is visible in the log.
app.Logger.LogInformation("Online deposits: {Gateway}.", mpgsOptions);
if (mpgsOptions.SendsThreeDsBypass)
    app.Logger.LogWarning("Online deposits: 3-D Secure BYPASS is on (TEST merchant profile, {Flag}). Never in production.", MpgsOptions.TestBypassKey);

// FIRST IN THE PIPELINE, and therefore INSIDE the developer exception page that WebApplication adds
// by itself in Development: the handler answers before that page can, so no environment returns a
// stack trace or SQL text from an API route. The empty lambda is deliberate — ApiExceptionHandler
// always writes the response, so there is no fallback branch to configure.
app.UseExceptionHandler(_ => { });

if (app.Environment.IsDevelopment())
{
    // AllowAnonymous because the authorization fallback would otherwise demand a token to read the
    // documentation — and the documentation is how you find out how to get one. Development only.
    app.MapOpenApi().AllowAnonymous();          // serves the spec at /openapi/v1.json
    app.MapScalarApiReference().AllowAnonymous(); // interactive UI at /scalar/v1
}

// NOTE FOR THE FINGERPRINT TERMINALS: this redirects plain HTTP to HTTPS with a 307, and ZKTeco
// firmware does not reliably follow redirects — a terminal configured against port 80 can sit there
// "connected" and never deliver a punch. If the device turns out not to speak TLS, the fix is to
// terminate TLS in front of the API (IIS/nginx) and let it forward on HTTP, NOT to drop this line:
// the serial and every punch travel in clear text, and the serial is the only credential this
// protocol has.
// /iclock is exempt because the terminals speak plain HTTP on the LAN and do not follow 307s; every
// other endpoint keeps the redirect.
app.UseWhen(
    ctx => !ctx.Request.Path.StartsWithSegments("/iclock"),
    branch => branch.UseHttpsRedirection());
app.UseCors(CorsPolicy);

// Before authentication on purpose: a flood should be refused at the door, not after we have done
// the work of trying to identify it. Only endpoints carrying [EnableRateLimiting] are affected —
// there is no global limiter, so every JWT-protected endpoint is untouched.
app.UseRateLimiter();

app.UseAuthentication();
app.UseAuthorization();
app.MapControllers();
app.MapHub<LiveHub>("/hubs/live");

// The website's confirmation page (anonymous, watches one reference) and the staff calendar (JWT,
// group "staff") both connect here, so its CORS policy is its own: BookingCorsOrigins + the staff
// front end, with credentials — see PublicBookingCorsPolicyProvider. RequireCors on the endpoint
// replaces the pipeline's default policy for this path only, negotiate and preflight included.
app.MapHub<BookingHub>("/hubs/booking")
   .RequireCors(PublicBookingCorsPolicyProvider.BookingHubCorsPolicy);

// THE SITE ROOT IS NOT AN ENDPOINT. Nothing is mapped to "/" — the API is controllers under /api,
// the terminals' /iclock, and the hub — so a browser opened at the bare host got a plain 404 that
// reads exactly like "the app failed to start". It did not; there was simply no route. These two
// answer that: "/" points a human at the documentation in Development, and /health is the one URL
// a load balancer or an installer can hit to confirm the process is alive without a token.
//
// AllowAnonymous on both, because the authorization fallback above demands an authenticated user
// for anything that does not say otherwise — and a liveness check that requires a login is not a
// liveness check.
var isDevelopment = app.Environment.IsDevelopment();

app.MapGet("/", () => isDevelopment
        ? Results.Redirect("/scalar/v1")
        : Results.Ok(new { service = "MokaCo.HRMS.API", status = "running", docs = "disabled outside Development" }))
   .AllowAnonymous()
   .ExcludeFromDescription();

app.MapGet("/health", () => Results.Ok(new
   {
       status = "ok",
       service = "MokaCo.HRMS.API",
       environment = app.Environment.EnvironmentName,
       utc = DateTime.UtcNow
   }))
   .AllowAnonymous()
   .ExcludeFromDescription();

// The one line an installer needs: exactly what to type into a terminal's Cloud Server / ADMS
// screen. Both halves are RESOLVED, never assumed — the LAN IP is per-machine and changes with the
// DHCP lease, and the port is whatever the profile actually bound. A guessed address here is
// indistinguishable from a dead terminal, which is the failure this line exists to prevent.
// Registered on ApplicationStarted because the server's real addresses do not exist until then.
app.Lifetime.ApplicationStarted.Register(() =>
{
    var bound = app.Services.GetRequiredService<IServer>()
        .Features.Get<IServerAddressesFeature>()?.Addresses ?? [];

    // "http://0.0.0.0:5078" / "http://[::]:5078" / "http://localhost:5078" — all we want is the port.
    var httpPort = bound
        .Select(address => Uri.TryCreate(address, UriKind.Absolute, out var uri) ? uri : null)
        .FirstOrDefault(uri => uri is not null && uri.Scheme == Uri.UriSchemeHttp)?.Port;

    // Every operational IPv4 that is not loopback — on a machine with Wi-Fi and Ethernet both up,
    // the installer needs to be told which addresses exist rather than handed one at random.
    var lanIPs = NetworkInterface.GetAllNetworkInterfaces()
        .Where(nic => nic.OperationalStatus == OperationalStatus.Up
                      && nic.NetworkInterfaceType != NetworkInterfaceType.Loopback)
        .SelectMany(nic => nic.GetIPProperties().UnicastAddresses)
        .Select(unicast => unicast.Address)
        .Where(ip => ip.AddressFamily == AddressFamily.InterNetwork && !IPAddress.IsLoopback(ip))
        .Select(ip => ip.ToString())
        .Distinct()
        .ToArray();

    var target = httpPort is null
        ? "no plain-HTTP binding — the terminals cannot reach this instance"
        : lanIPs.Length == 0
            ? $"http://<this machine's LAN IP>:{httpPort}"
            : string.Join(" or ", lanIPs.Select(ip => $"http://{ip}:{httpPort}"));

    app.Logger.LogInformation(
        "iclock receiver listening — point terminals at {Target} (device Cloud Server / ADMS " +
        "setting), serial must be registered on Attendance > Devices.", target);
});

app.Run();
