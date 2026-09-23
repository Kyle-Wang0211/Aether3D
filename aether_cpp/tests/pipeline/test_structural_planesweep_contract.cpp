#include "aether_structural_planesweep_c.h"

#include <cassert>
#include <cmath>
#include <cstdint>
#include <limits>

namespace {

void test_score_uses_exact_all_pairs_clique_and_parallax() {
    constexpr int views = 4;
    constexpr int points = 1;
    constexpr int samples = 3;
    const float unit = std::sqrt(0.5f);
    float patches[views * points * samples] = {
        unit, -unit, 0.0f,
        unit, -unit, 0.0f,
        unit, -unit, 0.0f,
        -unit, unit, 0.0f,
    };
    const std::uint8_t valid[views * points] = {1, 1, 1, 1};
    const std::uint8_t mask[points * views] = {1, 1, 1, 1};
    const float cameras[views * 3] = {
        1.0f, 0.0f, 0.0f,
        0.0f, 1.0f, 0.0f,
        -1.0f, 0.0f, 0.0f,
        0.0f, -1.0f, 0.0f,
    };
    const float world_points[points * 3] = {0.0f, 0.0f, 2.0f};
    aether_planesweep_birth_options_t options{};
    aether_planesweep_birth_options_default(&options);
    int supporting = 0;
    float ncc = 0.0f;
    float parallax = 0.0f;
    std::uint8_t accepted = 0;
    assert(aether_planesweep_score_scale(
               patches, valid, mask, cameras, world_points,
               views, points, samples, &options,
               &supporting, &ncc, &parallax, &accepted) ==
           AETHER_PLANESWEEP_OK);
    // The opposite fourth observation cannot enter the clique; the three
    // mutually consistent views remain and independently clear parallax.
    assert(accepted == 1);
    assert(supporting == 3);
    assert(std::fabs(ncc - 1.0f) < 1e-6f);
    assert(parallax > 5.0f);

    options.minimum_views = 4;
    assert(aether_planesweep_score_scale(
               patches, valid, mask, cameras, world_points,
               views, points, samples, &options,
               &supporting, &ncc, &parallax, &accepted) ==
           AETHER_PLANESWEEP_OK);
    assert(accepted == 0);
}

void test_score_selects_largest_clique_that_clears_parallax() {
    constexpr int views = 6;
    constexpr int points = 1;
    constexpr int samples = 4;
    constexpr float cosine = 0.9995f;
    const float sine = std::sqrt(1.0f - cosine * cosine);
    // Views 0..2 form the numerically strongest size-3 clique, but their
    // camera baseline is degenerate. Views 3..5 form another valid size-3
    // all-pairs clique within the frozen 0.001 JPEG-decoder tie band and with
    // real parallax. A tiny decoder perturbation must not hide it.
    const float patches[views * points * samples] = {
        1.0f, 0.0f, 0.0f, 0.0f,
        1.0f, 0.0f, 0.0f, 0.0f,
        1.0f, 0.0f, 0.0f, 0.0f,
        0.0f, 1.0f, 0.0f, 0.0f,
        0.0f, cosine, sine, 0.0f,
        0.0f, cosine, 0.0f, sine,
    };
    const std::uint8_t valid[views * points] = {1, 1, 1, 1, 1, 1};
    const std::uint8_t mask[points * views] = {1, 1, 1, 1, 1, 1};
    const float cameras[views * 3] = {
        0.0f, 0.0f, 0.0f,
        0.01f, 0.0f, 0.0f,
        0.0f, 0.01f, 0.0f,
        1.0f, 0.0f, 0.0f,
        0.0f, 1.0f, 0.0f,
        -1.0f, 0.0f, 0.0f,
    };
    const float world_points[points * 3] = {0.0f, 0.0f, 2.0f};
    aether_planesweep_birth_options_t options{};
    aether_planesweep_birth_options_default(&options);
    int supporting = 0;
    float ncc = 0.0f;
    float parallax = 0.0f;
    std::uint8_t accepted = 0;
    assert(aether_planesweep_score_scale(
               patches, valid, mask, cameras, world_points,
               views, points, samples, &options,
               &supporting, &ncc, &parallax, &accepted) ==
           AETHER_PLANESWEEP_OK);
    assert(accepted == 1);
    assert(supporting == 3);
    assert(std::fabs(ncc - cosine) < 1e-5f);
    assert(parallax > options.minimum_parallax_deg);
}

void test_grouped_competitor_uses_canonical_millincc_edge() {
    constexpr int candidates = 1;
    constexpr int hypotheses_per_candidate = 2;
    constexpr int views = 4;
    constexpr int points = candidates * hypotheses_per_candidate;
    constexpr int samples = 81;

    // Frozen cap51 legacy2/grid274 WGSL readback. Hypothesis 0 is the
    // structural-plane center; hypothesis 1 is its +0.05 m parallel-depth
    // competitor. Frames 41/40/16/15 provide the same four-view evidence used
    // by the independent reference evaluator. The competitor's frame-40 /
    // frame-15 edge is 0.7998066: raw float comparison drops the entire
    // four-view clique, while canonical millincc correctly retains edge 800.
    const float patches[views * points * samples] = {
        0.118389957f, 0.0825542137f, 0.0883791149f, -0.0237690117f, -0.108214207f, -0.109349653f,
        -0.115164109f, -0.111156583f, -0.109721392f, 0.209420443f, 0.0969268009f, 0.116406068f,
        0.0666263402f, -0.120194405f, -0.108830005f, -0.114457496f, -0.116730176f, -0.109873414f,
        0.160406142f, 0.116446942f, 0.147155955f, 0.130573079f, -0.0479904748f, -0.106969379f,
        -0.114395492f, -0.118928216f, -0.0976721272f, 0.126137674f, 0.144438565f, 0.111170277f,
        0.128081858f, 0.00422030129f, -0.107719444f, -0.115059741f, -0.115969695f, -0.110042788f,
        0.120351233f, 0.156775817f, 0.145327508f, 0.111493021f, 0.0578961298f, -0.105021432f,
        -0.110316627f, -0.111826405f, -0.122435182f, 0.124196947f, 0.134349361f, 0.127385885f,
        0.102281339f, 0.00672716415f, -0.104614556f, -0.113980003f, -0.116355367f, -0.126281992f,
        0.129284859f, 0.110457599f, 0.10950166f, 0.0607487857f, 0.071036607f, -0.115364581f,
        -0.110822707f, -0.114396788f, -0.123545669f, 0.125708356f, 0.115061253f, 0.108954817f,
        0.0596243441f, 0.0386888832f, -0.077088587f, -0.109933861f, -0.114332512f, -0.118099295f,
        0.128786296f, 0.117265254f, 0.108126767f, 0.0608795509f, -0.0901734903f, 0.0304523949f,
        -0.109943382f, -0.114745907f, -0.117211051f, 0.191510841f, 0.154220954f, 0.147742048f,
        -0.103995614f, -0.093482472f, -0.0979063585f, -0.101184905f, -0.0826890245f, -0.101518974f,
        0.192871109f, 0.128755763f, 0.0603380725f, 0.0245968644f, -0.0903740376f, -0.0947361067f,
        -0.101064183f, -0.104995817f, -0.0974951535f, 0.195653543f, 0.130484119f, 0.000162404103f,
        0.0927071795f, -0.0900089368f, -0.0968077928f, -0.0988322198f, -0.111662716f, -0.0917431489f,
        0.164728329f, 0.129661962f, 0.139580458f, -0.0592361204f, -0.0940900967f, -0.0947067589f,
        -0.0989648104f, -0.105688967f, -0.0802551359f, 0.167274788f, 0.132632837f, 0.12122006f,
        0.119144529f, -0.107525259f, -0.0912273079f, -0.10033007f, -0.100948922f, -0.0856754705f,
        0.122689798f, 0.115569972f, 0.101900369f, -0.0543082207f, 0.0206062477f, -0.0958983898f,
        -0.0995793417f, -0.0978730321f, -0.103659295f, 0.113548175f, 0.130732983f, 0.116334692f,
        0.118946716f, 0.013315401f, -0.0952003077f, -0.098041065f, -0.0998749956f, -0.115893379f,
        0.134452119f, 0.143351883f, 0.140228733f, 0.0916313678f, 0.0578492805f, -0.0990015045f,
        -0.0925192609f, -0.101662628f, -0.109714173f, 0.141722277f, 0.148740873f, 0.130887195f,
        0.118203081f, 0.0027033384f, -0.113962203f, -0.0951090604f, -0.100788675f, -0.106470764f,
        0.157785833f, 0.148951083f, 0.00821514055f, -0.0896273032f, -0.0908302814f, -0.072385937f,
        -0.0709435418f, -0.0652129799f, -0.0703703091f, 0.144447803f, 0.13960588f, 0.0570112206f,
        -0.109212674f, -0.0903682634f, -0.0689960718f, -0.0766318217f, -0.0705421641f, -0.0789218247f,
        0.142371714f, 0.123197228f, 0.0840150714f, -0.0597376153f, -0.0936801806f, -0.0852365047f,
        -0.0812555701f, -0.08118736f, -0.0843071938f, 0.169818774f, 0.112508349f, 0.12245433f,
        0.0132173616f, -0.0900708586f, -0.0927597284f, -0.0860758498f, -0.0866291672f, -0.0877889395f,
        0.208858952f, 0.132371962f, 0.127953425f, -0.000417191186f, -0.0905188024f, -0.0942592472f,
        -0.0824115127f, -0.0871159062f, -0.0903661624f, 0.223380774f, 0.157731086f, 0.153283894f,
        0.0334883146f, -0.0906649381f, -0.0968618691f, -0.091447629f, -0.0889451429f, -0.0925576016f,
        0.162693962f, 0.170089647f, 0.179746583f, 0.0364625379f, -0.0879846886f, -0.0935436487f,
        -0.0932663307f, -0.0851839259f, -0.0929362029f, 0.164517924f, 0.18997705f, 0.157901078f,
        0.0558214486f, -0.0873120651f, -0.091409944f, -0.0988797471f, -0.0861690864f, -0.0920570716f,
        0.165458947f, 0.174435779f, 0.164416313f, 0.0697654709f, -0.0874012187f, -0.0918617025f,
        -0.0967238396f, -0.0856924132f, -0.0931956097f, 0.259867013f, 0.212665722f, -0.0597606562f,
        -0.066262342f, -0.0713904947f, -0.068993412f, -0.0675368086f, -0.0695471764f, -0.0719529688f,
        0.278507173f, 0.180613428f, -0.0798946768f, -0.0659890473f, -0.0717712566f, -0.0694214776f,
        -0.0694879889f, -0.0704595223f, -0.0730142593f, 0.255423456f, 0.129910901f, -0.0362883024f,
        -0.0634847358f, -0.0659154728f, -0.0822614804f, -0.0657835975f, -0.0738898292f, -0.0728309676f,
        0.212765232f, 0.100381896f, 0.0751975179f, -0.0673034191f, -0.0700629428f, -0.0813935921f,
        -0.0615505204f, -0.0776741728f, -0.0768306255f, 0.217897609f, 0.129333138f, 0.10396377f,
        -0.0640961975f, -0.069177784f, -0.0774029046f, -0.0624406449f, -0.0800743401f, -0.0788657591f,
        0.170908436f, 0.180528447f, 0.0846103355f, -0.0695460364f, -0.0692119077f, -0.0756931379f,
        -0.0658636317f, -0.0798617601f, -0.0763064176f, 0.166956469f, 0.166257069f, 0.117230773f,
        -0.0778611302f, -0.0711571723f, -0.0758416206f, -0.0832678154f, -0.078974165f, -0.0781974047f,
        0.180190578f, 0.170008048f, 0.0777924061f, -0.0159996878f, -0.0746088773f, -0.0722544789f,
        -0.0847497061f, -0.0658366084f, -0.0788657591f, 0.173717156f, 0.154737622f, 0.0723110884f,
        0.08705879f, -0.0684889778f, -0.0752481818f, -0.0809356794f, -0.0583906099f, -0.0788657591f,
        0.259733915f, 0.172992736f, 0.0758108124f, -0.00725128548f, -0.0860239565f, -0.0908800289f,
        -0.0899681747f, -0.0923828259f, -0.0915383026f, 0.253292173f, 0.164745718f, 0.0963771492f,
        -0.00535890041f, -0.0710320175f, -0.0941760093f, -0.0920686349f, -0.0918832943f, -0.0915383026f,
        0.234639421f, 0.142799065f, 0.152750909f, -0.00857994426f, -0.0739848837f, -0.092112571f,
        -0.0943978578f, -0.0961622596f, -0.0932970271f, 0.205761865f, 0.12415313f, 0.107803084f,
        0.0380355045f, -0.0733756721f, -0.0915723443f, -0.0938643366f, -0.0942700356f, -0.0938643366f,
        0.187171817f, 0.129387766f, 0.114479169f, 0.0874629021f, -0.0638941601f, -0.0950098708f,
        -0.0941945612f, -0.0941190273f, -0.0938548744f, 0.186960667f, 0.135157973f, 0.0743327364f,
        0.0693339482f, -0.0796854347f, -0.0963484496f, -0.0945927799f, -0.0933560282f, -0.09353894f,
        0.150600001f, 0.0804556683f, 0.0581646226f, 0.062469501f, -0.0773098916f, -0.0943946615f,
        -0.094040364f, -0.0937381238f, -0.09540499f, 0.15851526f, 0.0812870786f, 0.0710141584f,
        0.0392237715f, -0.0831626952f, -0.0957474187f, -0.0949503183f, -0.0939826295f, -0.0983269587f,
        0.159774676f, 0.108658373f, 0.0839632824f, 0.0235184617f, -0.0786200911f, -0.0939808935f,
        -0.0967206955f, -0.0960810706f, -0.0961903706f, 0.19473511f, 0.160658777f, 0.0554980636f,
        -0.0553252324f, -0.0879484117f, -0.0843889192f, -0.0837220401f, -0.0857756436f, -0.0854910389f,
        0.228989989f, 0.144656181f, 0.0529610217f, -0.0737985075f, -0.0882322565f, -0.084357813f,
        -0.0837220401f, -0.0854372457f, -0.0865033492f, 0.226417676f, 0.131620511f, 0.0752643645f,
        -0.0612053387f, -0.0796612278f, -0.085895814f, -0.0853971839f, -0.0885690525f, -0.0818006694f,
        0.23697488f, 0.113935836f, 0.0612365045f, -0.0229794402f, -0.0821931511f, -0.0833888575f,
        -0.0855041519f, -0.0899775922f, -0.0870193541f, 0.224436224f, 0.148224562f, 0.0809648037f,
        -0.0131505588f, -0.0772764757f, -0.080341287f, -0.0819218904f, -0.0855787247f, -0.0817214996f,
        0.181697384f, 0.178916365f, 0.107076384f, -0.021622112f, -0.0767711103f, -0.0820786059f,
        -0.0815040991f, -0.0805156156f, -0.0812936798f, 0.161542922f, 0.183380619f, 0.112001628f,
        0.00953862071f, -0.0809715986f, -0.0805156156f, -0.0835094824f, -0.0832836926f, -0.080801405f,
        0.176792383f, 0.15858382f, 0.114776306f, -0.00448325509f, -0.0859920233f, -0.081757091f,
        -0.0835094824f, -0.0835094824f, -0.0846047699f, 0.186365172f, 0.1523536f, 0.157951608f,
        0.0048965863f, -0.0857364908f, -0.081590414f, -0.0858864486f, -0.0867559016f, -0.0874671414f,
        0.186603203f, 0.217199668f, 0.0802334026f, 0.0255663507f, -0.103995584f, -0.089548476f,
        -0.104796313f, -0.101634122f, -0.102185085f, 0.172624215f, 0.219017982f, 0.0555859357f,
        -0.0170461331f, -0.111227758f, -0.0909935012f, -0.106764622f, -0.10350094f, -0.103970066f,
        0.199973315f, 0.192584604f, 0.0486319549f, -0.0104175331f, -0.0447956175f, -0.0780468062f,
        -0.103407815f, -0.103216365f, -0.104990497f, 0.196199596f, 0.185218275f, 0.0912937075f,
        0.0409669541f, -0.00742778089f, -0.0895314217f, -0.103111982f, -0.103690274f, -0.104585998f,
        0.184082836f, 0.158853829f, 0.0820517316f, 0.0309135038f, -0.00436637271f, -0.0900179669f,
        -0.104663044f, -0.104990497f, -0.104990497f, 0.185114413f, 0.130425721f, 0.0566800088f,
        0.067472823f, -0.0241333432f, -0.0931340754f, -0.105097726f, -0.105185471f, -0.104990497f,
        0.191948578f, 0.104059182f, 0.0380764455f, 0.0405779183f, 0.0205969755f, -0.104427554f,
        -0.100267142f, -0.10558603f, -0.104990497f, 0.197330371f, 0.0839246958f, 0.0607645661f,
        0.0506255478f, 0.0237686988f, -0.0972425342f, -0.0961617008f, -0.106343724f, -0.108134255f,
        0.203241363f, 0.0774511993f, 0.0160618462f, 0.0150139006f, -0.000301805936f, -0.0731840804f,
        -0.0870834291f, -0.109892517f, -0.106668957f, 0.146591261f, 0.182752505f, 0.0738237798f,
        0.0650823936f, -0.0851290599f, -0.10277921f, -0.102930151f, -0.104877479f, -0.107300706f,
        0.112990268f, 0.15045841f, 0.0894228816f, 0.0650245026f, -0.0999028534f, -0.101170331f,
        -0.102206513f, -0.104169689f, -0.112683542f, 0.131046742f, 0.186692297f, 0.110386208f,
        0.0465595014f, -0.122043401f, -0.0827420801f, -0.112685703f, -0.102804013f, -0.107103415f,
        0.11512994f, 0.155560747f, 0.124876156f, 0.0186997987f, -0.093898952f, -0.0843402669f,
        -0.110916018f, -0.110330194f, -0.113108084f, 0.113330588f, 0.116798222f, 0.107125074f,
        0.0399486423f, -0.0774572939f, -0.0858647004f, -0.108376108f, -0.106277481f, -0.104260154f,
        0.119354635f, 0.131659672f, 0.0998969898f, 0.0832588747f, -0.00212253584f, -0.0868112519f,
        -0.118793353f, -0.113355033f, -0.107548177f, 0.119577117f, 0.189764485f, 0.0804738402f,
        0.0951607898f, 0.0460730419f, -0.0908416137f, -0.104169689f, -0.110935882f, -0.114749253f,
        0.146452308f, 0.120443761f, 0.0876664668f, 0.0882579535f, 0.0670283735f, -0.114014864f,
        -0.105586678f, -0.103844754f, -0.111165531f, 0.251857787f, 0.127700388f, 0.155318588f,
        0.0806496367f, 0.0127961272f, -0.1093437f, -0.100919932f, -0.112036929f, -0.104090594f,
    };
    const std::uint8_t valid[views * points] = {1, 1, 1, 1, 1, 1, 1, 1};
    const std::uint8_t mask[points * views] = {1, 1, 1, 1, 1, 1, 1, 1};
    const float cameras[views * 3] = {
        0.614206254f, -0.2323073f, 1.22293329f,
        0.39014709f, -0.256979674f, 1.15340948f,
        -0.917273581f, -0.271641403f, 1.04492474f,
        -0.917699277f, -0.174371496f, 0.992830515f,
    };
    const float world_points[points * 3] = {
        2.52152395f, -0.672981679f, 0.537167668f,
        2.54499674f, -0.672774017f, 0.493020386f,
    };
    aether_planesweep_birth_options_t options{};
    aether_planesweep_birth_options_default(&options);
    options.minimum_views = 4;
    options.ncc_min = 0.8f;
    options.minimum_parallax_deg = 10.0f;
    options.unique_depth_margin = 0.02f;

    int supporting[points]{};
    float ncc[points]{};
    float parallax[points]{};
    std::uint8_t score_valid[points]{};
    assert(aether_planesweep_score_scale_grouped(
               patches, valid, mask, cameras, world_points,
               views, points, samples, hypotheses_per_candidate, &options,
               supporting, ncc, parallax, score_valid) ==
           AETHER_PLANESWEEP_OK);
    assert(score_valid[0] == 1);
    assert(score_valid[1] == 1);
    assert(supporting[0] == 4);
    assert(supporting[1] == 4);
    assert(parallax[0] > options.minimum_parallax_deg);
    assert(parallax[1] > options.minimum_parallax_deg);
    assert(ncc[0] - ncc[1] < options.unique_depth_margin);

    // The exact same +5 cm evidence remains ineligible when evaluated as a
    // center hypothesis: decoder tolerance is allowed to preserve an
    // ambiguity competitor, never to create a new product birth.
    float competitor_patches[views * samples]{};
    for (int view = 0; view < views; ++view) {
        for (int sample = 0; sample < samples; ++sample) {
            competitor_patches[view * samples + sample] =
                patches[(view * points + 1) * samples + sample];
        }
    }
    const std::uint8_t competitor_valid[views] = {1, 1, 1, 1};
    const std::uint8_t competitor_mask[views] = {1, 1, 1, 1};
    int competitor_supporting = 0;
    float competitor_ncc = 0.0f;
    float competitor_parallax = 0.0f;
    std::uint8_t competitor_score_valid = 0;
    assert(aether_planesweep_score_scale(
               competitor_patches, competitor_valid, competitor_mask, cameras,
               world_points + 3, views, 1, samples, &options,
               &competitor_supporting, &competitor_ncc,
               &competitor_parallax, &competitor_score_valid) ==
           AETHER_PLANESWEEP_OK);
    assert(competitor_score_valid == 0);

    aether_planesweep_candidate_result_t results[candidates]{};
    assert(aether_planesweep_apply_unique_depth(
               candidates, hypotheses_per_candidate, supporting, ncc,
               parallax, score_valid, &options, results, candidates, 0) ==
           AETHER_PLANESWEEP_OK);
    assert(results[0].accepted == 0);
}


void test_unique_depth_is_fail_closed_and_rescue_only() {
    constexpr int candidates = 2;
    constexpr int hypotheses = 3;
    const int supporting[candidates * hypotheses] = {
        5, 5, 4,
        5, 6, 4,
    };
    const float ncc[candidates * hypotheses] = {
        0.95f, 0.85f, 0.80f,
        0.91f, 0.80f, 0.70f,
    };
    const float parallax[candidates * hypotheses] = {
        18.0f, 18.0f, 18.0f,
        19.0f, 19.0f, 19.0f,
    };
    const std::uint8_t valid[candidates * hypotheses] = {
        1, 1, 1,
        1, 1, 0,
    };
    aether_planesweep_birth_options_t options{};
    aether_planesweep_birth_options_default(&options);
    options.unique_depth_margin = 0.06f;
    aether_planesweep_candidate_result_t results[candidates]{};
    assert(aether_planesweep_apply_unique_depth(
               candidates, hypotheses, supporting, ncc, parallax, valid,
               &options, results, candidates, 0) == AETHER_PLANESWEEP_OK);
    assert(results[0].accepted == 1);
    assert(results[0].supporting_views == 5);
    assert(std::fabs(results[0].observed_depth_margin - 0.10f) < 1e-6f);
    // Candidate 1 has a numerically lower alternative but that alternative
    // has more independent views, so the structural plane cannot own birth.
    assert(results[1].accepted == 0);

    results[1].accepted = 1;
    results[1].median_ncc = 0.99f;
    assert(aether_planesweep_apply_unique_depth(
               candidates, hypotheses, supporting, ncc, parallax, valid,
               &options, results, candidates, 1) == AETHER_PLANESWEEP_OK);
    assert(results[1].accepted == 1);
    assert(std::fabs(results[1].median_ncc - 0.99f) < 1e-6f);
}

void test_unique_depth_uses_canonical_millincc_decision_units() {
    constexpr int candidates = 4;
    constexpr int hypotheses = 2;
    const int supporting[candidates * hypotheses] = {
        5, 5, 5, 5, 5, 5, 5, 5};
    const float ncc[candidates * hypotheses] = {
        // Both values quantize to a 20-unit gap, but the raw gap is below
        // 0.02. This rounded-up boundary must fail closed.
        0.948780954f, 0.929353535f,
        // This pair also quantizes to 20 units, while its raw gap genuinely
        // clears 0.02. It must retain ownership.
        0.93846786f, 0.917997718f,
        // A genuine 19-unit separation remains rejected.
        0.9242f, 0.9053f,
        // JPEG decoders disagree across the raw 0.02 boundary for this pair:
        // the canonical gap is 20 units and the center has independently
        // strong geometry. The geometry-backed boundary must survive without
        // weakening the ordinary low-parallax boundary above.
        0.92472291f, 0.90526712f,
    };
    const float parallax[candidates * hypotheses] = {
        17.6f, 17.0f,
        13.2f, 13.0f,
        55.0f, 54.0f,
        55.7f, 54.6f,
    };
    const std::uint8_t valid[candidates * hypotheses] = {
        1, 1, 1, 1, 1, 1, 1, 1,
    };
    aether_planesweep_birth_options_t options{};
    aether_planesweep_birth_options_default(&options);
    options.minimum_parallax_deg = 10.0f;
    aether_planesweep_candidate_result_t results[candidates]{};
    assert(aether_planesweep_apply_unique_depth(
               candidates, hypotheses, supporting, ncc, parallax, valid,
               &options, results, candidates, 0) == AETHER_PLANESWEEP_OK);
    assert(results[0].accepted == 0);
    assert(results[1].accepted == 1);
    assert(std::fabs(results[1].observed_depth_margin - 0.020f) < 1e-6f);
    assert(results[2].accepted == 0);
    assert(results[3].accepted == 1);
    assert(std::fabs(results[3].observed_depth_margin - 0.020f) < 1e-6f);
}

void test_unique_depth_rejects_non_finite_evidence() {
    constexpr int candidates = 1;
    constexpr int hypotheses = 2;
    const int supporting[candidates * hypotheses] = {4, 4};
    const std::uint8_t valid[candidates * hypotheses] = {1, 1};
    aether_planesweep_birth_options_t options{};
    aether_planesweep_birth_options_default(&options);
    aether_planesweep_candidate_result_t results[candidates]{};

    float ncc[candidates * hypotheses] = {
        std::numeric_limits<float>::quiet_NaN(), 0.80f};
    float parallax[candidates * hypotheses] = {15.0f, 15.0f};
    assert(aether_planesweep_apply_unique_depth(
               candidates, hypotheses, supporting, ncc, parallax, valid,
               &options, results, candidates, 0) == AETHER_PLANESWEEP_OK);
    assert(results[0].accepted == 0);

    ncc[0] = 0.90f;
    ncc[1] = std::numeric_limits<float>::infinity();
    assert(aether_planesweep_apply_unique_depth(
               candidates, hypotheses, supporting, ncc, parallax, valid,
               &options, results, candidates, 0) == AETHER_PLANESWEEP_OK);
    assert(results[0].accepted == 0);

    ncc[1] = 0.80f;
    parallax[1] = std::numeric_limits<float>::quiet_NaN();
    assert(aether_planesweep_apply_unique_depth(
               candidates, hypotheses, supporting, ncc, parallax, valid,
               &options, results, candidates, 0) == AETHER_PLANESWEEP_OK);
    assert(results[0].accepted == 0);

    parallax[1] = 15.0f;
    options.unique_depth_margin =
        std::numeric_limits<float>::quiet_NaN();
    assert(aether_planesweep_apply_unique_depth(
               candidates, hypotheses, supporting, ncc, parallax, valid,
               &options, results, candidates, 0) ==
           AETHER_PLANESWEEP_ERR_BAD_ARGS);
}

void test_post_quality_gate_cannot_weaken_scale_rescue() {
    constexpr int candidates = 1;
    constexpr int hypotheses = 1;
    const int supporting[] = {5};
    const float ncc[] = {0.91f};
    const float parallax[] = {18.0f};
    const std::uint8_t valid[] = {1};
    aether_planesweep_birth_options_t options{};
    aether_planesweep_birth_options_default(&options);
    aether_planesweep_candidate_result_t results[candidates]{};

    options.post_minimum_views = 6;
    assert(aether_planesweep_apply_unique_depth(
               candidates, hypotheses, supporting, ncc, parallax, valid,
               &options, results, candidates, 0) == AETHER_PLANESWEEP_OK);
    assert(results[0].accepted == 0);

    options.post_minimum_views = 5;
    options.post_minimum_parallax_deg = 19.0f;
    assert(aether_planesweep_apply_unique_depth(
               candidates, hypotheses, supporting, ncc, parallax, valid,
               &options, results, candidates, 0) == AETHER_PLANESWEEP_OK);
    assert(results[0].accepted == 0);

    options.post_minimum_parallax_deg = 18.0f;
    options.post_min_ncc = 0.92f;
    assert(aether_planesweep_apply_unique_depth(
               candidates, hypotheses, supporting, ncc, parallax, valid,
               &options, results, candidates, 0) == AETHER_PLANESWEEP_OK);
    assert(results[0].accepted == 0);

    options.post_min_ncc = 0.91f;
    assert(aether_planesweep_apply_unique_depth(
               candidates, hypotheses, supporting, ncc, parallax, valid,
               &options, results, candidates, 0) == AETHER_PLANESWEEP_OK);
    assert(results[0].accepted == 1);
}

void test_dawn_session_is_explicitly_unsupported_without_dawn() {
#if !defined(AETHER_ENABLE_DAWN)
    aether_planesweep_session_options_t options{};
    aether_planesweep_session_options_default(&options);
    options.point_count = 1;
    options.candidate_count = 1;
    options.hypotheses_per_candidate = 1;
    const float point[3] = {0.0f, 0.0f, 1.0f};
    aether_planesweep_session_t* session = nullptr;
    assert(aether_planesweep_session_create(&options, point, &session) ==
           AETHER_PLANESWEEP_ERR_UNSUPPORTED);
    assert(session == nullptr);
#endif
}

}  // namespace

int main() {
    test_score_uses_exact_all_pairs_clique_and_parallax();
    test_score_selects_largest_clique_that_clears_parallax();
    test_grouped_competitor_uses_canonical_millincc_edge();
    test_unique_depth_is_fail_closed_and_rescue_only();
    test_unique_depth_uses_canonical_millincc_decision_units();
    test_unique_depth_rejects_non_finite_evidence();
    test_post_quality_gate_cannot_weaken_scale_rescue();
    test_dawn_session_is_explicitly_unsupported_without_dawn();
    return 0;
}
