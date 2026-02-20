<style>
  html {
    scroll-behavior: smooth;
  }

  .triple-arrow-container {
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    
    /* 1. STICKY TO BOTTOM */
    position: fixed;
    bottom: 30px; /* Distance from the bottom of the screen */
    left: 50%;
    transform: translateX(-50%); /* Centers it horizontally */
    z-index: 50; /* Keeps it above the WebGPU background */

    width: 100px;
    height: 100px;
    cursor: pointer;
    text-decoration: none;
    opacity: 0.6; 
    transition: opacity 0.3s ease, transform 0.3s ease;
  }

  /* 2. HOVER EFFECTS */
  .triple-arrow-container:hover {
    /* We use a compound transform so it stays centered while hovering */
    transform: translateX(-50%) translateY(5px); 
    opacity: 1 !important; /* Forces full visibility on hover */
  }

  .triple-arrow-container:hover .chevron path {
    stroke: #ff4d4d;
    filter: drop-shadow(0 0 8px #ff4d4d); /* Added a slight neon glow */
  }

  .chevron {
    display: block;
    margin-top: -8px; 
    filter: drop-shadow(0px 0px 5px rgba(0,0,0,0.3));
  }
  
  .chevron path {
    transition: stroke 0.4s ease;
  }

  /* 3. BOUNCE (Adjusted for fixed position) */
  .bounce-animation {
    animation: triple-bounce 2s infinite;
  }

  @keyframes triple-bounce {
    0%, 20%, 50%, 80%, 100% { margin-bottom: 0; }
    40% { margin-bottom: 15px; }
    60% { margin-bottom: 7px; }
  }
</style>

<a href="#recent-posts" id="scroll-arrow" class="triple-arrow-container bounce-animation">
  <svg class="chevron" width="30" height="20" viewBox="0 0 20 10">
    <path d="M1 1 L10 9 L19 1" fill="none" stroke="white" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>
  </svg>
  <svg class="chevron" width="40" height="22" viewBox="0 0 20 10">
    <path d="M1 1 L10 9 L19 1" fill="none" stroke="white" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>
  </svg>
  <svg class="chevron" width="50" height="25" viewBox="0 0 20 10">
    <path d="M1 1 L10 9 L19 1" fill="none" stroke="white" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>
  </svg>
</a>

<script>
  window.addEventListener('scroll', function() {
    var arrow = document.getElementById('scroll-arrow');
    var scrollPosition = window.scrollY;
    
    // As you scroll down (from 0 to 300px), opacity goes from 0.6 to 0
    var newOpacity = 0.6 - (scrollPosition / 300);
    
    if (newOpacity < 0) {
      arrow.style.opacity = 0;
      arrow.style.pointerEvents = 'none'; // Prevents clicking when invisible
    } else {
      arrow.style.opacity = newOpacity;
      arrow.style.pointerEvents = 'auto';
    }
  });
</script>

<div id="recent-posts" style="margin-top: 50vh;"></div>